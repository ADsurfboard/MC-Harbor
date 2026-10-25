"""Real HMCL engine checks in a separate APFS-cloned library. Never edits the user's instances."""
from pathlib import Path
import hashlib, json, os, shutil, subprocess, time, zipfile

ROOT=Path(__file__).resolve().parent.parent
EVIDENCE=ROOT/'evidence'
QA=EVIDENCE/'engine-qa'
DATA=EVIDENCE/'engine-data'
QA.mkdir(parents=True,exist_ok=True);DATA.mkdir(parents=True,exist_ok=True)
JDK=Path('/Library/Java/JavaVirtualMachines/liberica-jdk-21.jdk/Contents/Home')
FX=list(Path('/Applications/.hmcl/dependencies/macos-arm64/openjfx').glob('*21.0.8*.jar'))
CP=os.pathsep.join(map(str,[ROOT/'build/Backend.jar',Path('/Applications/稳定版我的世界启动器.jar')]+FX))
BASE=[str(JDK/'bin/java'),'-Xms32m','-Xmx384m','-Djava.awt.headless=true','-Dshenggan.headless=true','-Dhmcl.dir='+str(DATA),'-cp',CP,'net.morben.shenggan.NativeBridge']
REPORT={}

def call(command, timeout=180, **arguments):
    request={'command':command,'root':str(QA),'source':'auto','threads':8,**arguments}
    logfile=EVIDENCE/('engine-'+command+'.stderr')
    start=time.monotonic()
    with logfile.open('w') as err:
        process=subprocess.Popen(BASE,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err,text=True)
        process.stdin.write(json.dumps(request)+'\n');process.stdin.close()
        output=[]
        # communicate cannot be used after closing stdin; poll protocol in a bounded worker process instead.
        import threading
        def watchdog():
            try:process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:process.terminate()
        threading.Thread(target=watchdog,daemon=True).start()
        for line in process.stdout:
            obj=json.loads(line);output.append(obj)
            if obj.get('event')=='progress' and obj.get('message'):print(command+': '+obj['message'][:100],flush=True)
        code=process.wait()
    (EVIDENCE/('engine-'+command+'.jsonl')).write_text('\n'.join(json.dumps(o,ensure_ascii=False) for o in output))
    if code:raise RuntimeError(command+': '+str(next((x for x in output if x.get('event')=='error'),{'error':'exit '+str(code)})))
    result=next(x['data'] for x in output if x.get('event')=='result')
    REPORT[command]={'seconds':round(time.monotonic()-start,2),'result':result}
    (EVIDENCE/'engine-report.json').write_text(json.dumps(REPORT,ensure_ascii=False,indent=2))
    print(command+': passed',flush=True)
    return result

def main():
    call('diagnostics',timeout=35)
    original=Path('/Applications/.minecraft')
    for name in ['libraries','assets']:
        target=QA/name
        if not target.exists():
            print('APFS clone '+name,flush=True)
            subprocess.run(['/bin/cp','-cR',str(original/name),str(target)],check=True)
    instance='Harbor-QA-1.20.1'
    if not (QA/'versions'/instance/(instance+'.json')).exists():call('install',timeout=240,version='1.20.1',name=instance,loader='vanilla')
    else:REPORT['install']={'reusedQAInstance':True}
    run=QA/'versions'/instance
    # A known world fixture verifies paths, byte preservation and archive CRC without loading a user save.
    world=run/'saves'/'Harbor-QA';world.mkdir(parents=True,exist_ok=True)
    payload=b'harbor-archive-fixture\0'+bytes(range(256))*20
    (world/'level.dat').write_bytes(payload)
    (world/'region').mkdir(exist_ok=True);(world/'region'/'r.0.0.mca').write_bytes(payload*3)
    (run/'options.txt').write_text('music:0.25\n')
    archived=call('backup',runDirectory=str(run))
    with zipfile.ZipFile(archived['path']) as archive:
        assert archive.testzip() is None
        assert archive.read('saves/Harbor-QA/level.dat')==payload
        assert archive.read('saves/Harbor-QA/region/r.0.0.mca')==payload*3
    exported=call('export',id=instance,runDirectory=str(run))
    with zipfile.ZipFile(exported['path']) as archive:
        assert archive.testzip() is None
        assert {'mmc-pack.json','instance.cfg','.packignore'}.issubset(set(archive.namelist()))
        assert json.loads(archive.read('mmc-pack.json'))['components'][0]['version']=='1.20.1'
    imported='Harbor-QA-Roundtrip'
    if not (QA/'versions'/imported).exists():call('import',timeout=240,file=exported['path'],name=imported)
    assert (QA/'versions'/imported/'saves'/'Harbor-QA'/'level.dat').read_bytes()==payload
    REPORT['roundtrip']={'worldBytesMatch':True,'multiMCManifest':True,'crc':True}
    (EVIDENCE/'engine-report.json').write_text(json.dumps(REPORT,ensure_ascii=False,indent=2))
    print('All engine checks passed',flush=True)

if __name__=='__main__':main()
