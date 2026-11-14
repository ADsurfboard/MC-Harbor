"""Exercise the packaged shortcut and real launcher, using a disposable backend recorder."""
from pathlib import Path
import json, os, plistlib, shutil, signal, subprocess, tempfile, time, uuid

ROOT=Path(__file__).resolve().parent.parent
REGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
with tempfile.TemporaryDirectory(prefix='mcharbor-shortcut-') as temporary:
    qa=Path(temporary).resolve();app=qa/'Shortcut QA.app';helper=qa/'Quick Launch.app'
    shutil.copytree(ROOT/'build/MC Harbor.app',app,symlinks=True)
    info_file=app/'Contents/Info.plist';info=plistlib.loads(info_file.read_bytes());info['CFBundleIdentifier']='net.morben.harbor.shortcut-qa.'+uuid.uuid4().hex;info['CFBundleName']='Shortcut QA';
    if os.environ.get('GITHUB_ACTIONS')=='true':
        # Hosted Intel guests expose an AppleParavirt GPU with no matching RenderBox archive slice.
        # Compile the same pipelines instead; leave Metal errors, rendering and every assertion enabled.
        info.setdefault('LSEnvironment',{})['RB_USE_BINARY_ARCHIVE']='0'
        print('CI virtual GPU: compile RenderBox pipelines without its unsupported binary archive cache.',flush=True)
    info_file.write_bytes(plistlib.dumps(info))
    resources=app/'Contents/Resources';(resources/'Services.json').write_text('{"friends":""}')
    (qa/'MCHarbor.portable').touch();data=qa/'MCHarborData';library=data/'game';game=library/'versions/快捷启动 中文';game.mkdir(parents=True)
    (game/(game.name+'.json')).write_text(json.dumps({'id':game.name,'gameVersion':'1.20.1','mainClass':'net.minecraft.client.main.Main','type':'release','libraries':[],'arguments':{'game':[],'jvm':[]}}))
    (data/'preferences.json').write_text(json.dumps({'gameRoot':str(library),'selectedGame':'','introEnabled':False,'soundsEnabled':False,'voiceEnabled':False,'selectedAccount':'qa-offline'}))
    (data/'migration.json').write_text(json.dumps({'date':0,'importedAccounts':0,'existingAccounts':1,'libraries':[str(library)],'instances':1,'failures':[],'backup':''}))
    (data/'accounts.json').write_text(json.dumps([{'id':'qa-offline','name':'ShortcutQA','kind':'offline','uuid':''}]))
    receipt=qa/'dispatch.json';bridge=resources/'Runtime/bin/java';bridge.unlink()
    bridge.write_text('''#!/usr/bin/python3
import sys,json,os
from pathlib import Path
request=json.load(sys.stdin)
receipt=Path(RECEIPT)
if request.get("command")=="launch":
 records=json.loads(receipt.read_text()) if receipt.exists() else []
 records.append({k:request.get(k) for k in ["command","id","root","accountType"]});receipt.write_text(json.dumps(records))
 print(json.dumps({"event":"launched","pid":os.getpid()}),flush=True)
print(json.dumps({"event":"result","data":{}}),flush=True)
'''.replace('RECEIPT',repr(str(receipt))));bridge.chmod(0o755)
    token=str(uuid.uuid4());manifest=data/'instance-shortcuts.json';manifest.write_text(json.dumps({token:{'instance':game.name,'library':str(library)}}));manifest.chmod(0o600)
    macos=helper/'Contents/MacOS';macos.mkdir(parents=True);shutil.copy2(resources/'InstanceShortcut',macos/'InstanceShortcut')
    (helper/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleName':'Quick Launch QA','CFBundleExecutable':'InstanceShortcut','CFBundleIdentifier':info['CFBundleIdentifier']+'.helper','CFBundlePackageType':'APPL','LSUIElement':True,'HarborURL':'mcharbor://launch/'+token,'HarborApplication':str(app),'HarborDataRoot':str(data),'HarborBundleID':info['CFBundleIdentifier']}))
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
    children=[]
    helper_log=qa/'helper.log'
    def diagnostics():
        preferences=json.loads((data/'preferences.json').read_text())
        listing=subprocess.run(['ps','-axo','pid=,command='],capture_output=True,text=True).stdout
        executable=str(app/'Contents/MacOS/MCHarbor')
        owned=[line.strip().split(maxsplit=1)[0] for line in listing.splitlines() if executable in line]
        crashes=[]
        for report in sorted((Path.home()/'Library/Logs/DiagnosticReports').glob('MCHarbor*.ips'),key=lambda p:p.stat().st_mtime,reverse=True)[:3]:
            raw=report.read_text(errors='replace')
            if info['CFBundleIdentifier'] in raw:crashes.append(raw[:14000])
        return {'crashes':crashes,'selected':preferences.get('selectedGame'),'library':preferences.get('gameRoot'),'helperExit':[c.poll() for c in children],'launcherPIDs':owned,'pendingRequests':[p.read_text()[:4096] for p in (data/'shortcut-inbox').glob('*.json')],'helperLog':helper_log.read_text()[-3000:] if helper_log.exists() else '', 'backendRecorderExists':bridge.is_file(),'systemPython':subprocess.run(['/usr/bin/python3','--version'],capture_output=True,text=True).stdout.strip()}

    try:
        for attempt in [1,2]:
            with helper_log.open('ab') as log:child=subprocess.Popen([str(macos/'InstanceShortcut')],stdout=log,stderr=log)
            children.append(child)
            deadline=time.monotonic()+60
            while time.monotonic()<deadline:
                if receipt.exists() and len(json.loads(receipt.read_text()))>=attempt:break
                time.sleep(0.2)
            else:raise RuntimeError('No instance dispatch for '+('cold' if attempt==1 else 'warm')+' shortcut; diagnostics: '+json.dumps(diagnostics(),ensure_ascii=False))
            record=json.loads(receipt.read_text())[-1]
            assert record['id']==game.name and record['accountType']=='offline' and record['root']==str(library),record
            child.wait(timeout=15)
            assert child.returncode == 0, 'Shortcut helper exited unsuccessfully'
            assert len(json.loads(receipt.read_text())) == attempt, 'Shortcut launched the instance more than once'
            assert not list((data/'shortcut-inbox').glob('*.json')), 'Consumed shortcut request was retained'
            if attempt==1:time.sleep(2)  # Allow the recorder's exit callback to release the running-game state.
            print('PASS '+('cold' if attempt==1 else 'warm')+' packaged shortcut dispatches the selected instance',flush=True)
        print('Boundary: real launcher and helper; game JVM replaced by a protocol recorder.',flush=True)
    finally:
        for child in children:
            if child.poll() is None:child.terminate();child.wait(timeout=5)
        executable=str(app/'Contents/MacOS/MCHarbor')
        listing=subprocess.run(['ps','-axo','pid=,command='],capture_output=True,text=True,check=True)
        for line in listing.stdout.splitlines():
            parts=line.strip().split(maxsplit=1)
            if len(parts)==2 and (parts[1]==executable or parts[1].startswith(executable+' ')):
                try:os.kill(int(parts[0]),signal.SIGTERM)
                except ProcessLookupError:pass
        for item in [app,helper]:subprocess.run([REGISTER,'-u',str(item)],capture_output=True)
        installed=Path('/Applications/MC Harbor.app')
        if installed.exists():subprocess.run([REGISTER,'-f',str(installed)],capture_output=True)
