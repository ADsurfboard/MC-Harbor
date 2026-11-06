"""Run the official x86 Terracotta daemon through the production Swift client in isolation."""
from pathlib import Path
import hashlib,json,os,shutil,signal,subprocess,tempfile

root=Path(__file__).resolve().parent.parent
evidence=root/'evidence';evidence.mkdir(exist_ok=True)
existing=Path.home()/'terracotta'
def snapshot(folder):
    if not folder.exists():return {}
    return {str(p.relative_to(folder)):('symlink:'+os.readlink(p) if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest()) for p in folder.rglob('*') if p.is_symlink() or p.is_file()}
before=snapshot(existing)
with tempfile.TemporaryDirectory(prefix='intel-terracotta-',dir=evidence) as temporary:
    folder=Path(temporary);config=folder/'config.json';config.write_text(json.dumps({'terracotta':True}))
    client=folder/'client';client.mkdir()
    environment=dict(os.environ,SHENGGAN_BACKEND_RESOURCES=str(root/'build/MC Harbor.app/Contents/Resources'))
    process=subprocess.Popen([str(root/'build/update-checks'),str(config),str(client),str(root/'Assets')],env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    try:stdout,stderr=process.communicate(timeout=190)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGTERM);process.communicate(timeout=10);raise
    print(stdout,end='')
    if process.returncode:
        print(stderr);raise SystemExit(process.returncode)
    report=json.loads((folder/'terracotta-native-report.json').read_text())
    assert report['nativeHostStarts'] and report['nativeStopResets']
    sandbox=client/'network/terracotta/runtime/terracotta'
    assert (sandbox/'terracotta.lock').is_file(),'Private daemon lock missing'
    assert before==snapshot(existing),'Existing Terracotta files changed'
    module=next((client/'network/terracotta').glob('terracotta-*'))
    assert module.read_bytes()[:8]==bytes([207,250,237,254,7,0,0,1])
    report.update(existingTerracottaUntouched=True,privateWorkingDirectory=True,officialBinaryArchitecture='x86_64')
    (evidence/'intel-terracotta-report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False))
    print('Official Intel module started and stopped; existing Terracotta data preserved')
