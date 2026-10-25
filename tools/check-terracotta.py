"""Real official macOS core / HTTP state checks; no claim of two-network game play."""
from pathlib import Path
import hashlib,json,os,subprocess,tarfile,time,urllib.request

root=Path(__file__).resolve().parent.parent
folder=root/'evidence/terracotta-core-qa';folder.mkdir(exist_ok=True)
archive=root/'evidence/research/blockhelm/terracotta-0.4.2-macos-arm64-pkg.tar.gz'
expected='13de7f9ce8733971b23493fabbe7e16d480f1e0d16a6265b4861f5a01bbecb60'
checks={}
def check(name,value):checks[name]=bool(value);print(('PASS ' if value else 'FAIL ')+name,flush=True)
check('official-publisher-archive-SHA256',hashlib.sha256(archive.read_bytes()).hexdigest()==expected)
assert checks['official-publisher-archive-SHA256']
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
lock=Path.home()/'terracotta/terracotta.lock'
if lock.exists() and len(lock.read_bytes())==2:
    port=int.from_bytes(lock.read_bytes(),'big')
    try:
        opener.open('http://127.0.0.1:'+str(port)+'/meta',timeout=2)
        raise SystemExit('A live core already exists; refusing to change its state')
    except OSError:pass
binary=folder/'terracotta-official'
with tarfile.open(archive,'r:gz') as tar:
    name='terracotta-0.4.2-macos-arm64'
    stream=tar.extractfile(name);assert stream is not None;content=stream.read()
check('MachO-ARM64-module',content[:8]==bytes([207,250,237,254,12,0,0,1]))
binary.write_bytes(content);binary.chmod(0o700)
handoff=folder/'handoff.json'
for file in [handoff,Path(str(handoff)+'.tmp')]:file.unlink(missing_ok=True)
process=None
try:
    log=(folder/'core.log').open('w')
    process=subprocess.Popen([str(binary),'--daemon'],cwd=folder,stdout=log,stderr=log,stdin=subprocess.DEVNULL)
    for _ in range(200):
        if lock.exists() and len(lock.read_bytes())==2:break
        if process.poll() is not None:raise RuntimeError('Official core exited before handoff')
        time.sleep(.1)
    port=int.from_bytes(lock.read_bytes(),'big');check('official-daemon-port-discovery',isinstance(port,int) and 0<port<65536)
    def get(path):
        with opener.open('http://127.0.0.1:'+str(port)+path,timeout=4) as response:
            raw=response.read();return json.loads(raw) if raw else {}
    for _ in range(60):
        try:meta=get('/meta');break
        except OSError:time.sleep(.1)
    check('real-macOS-meta',meta.get('target_os')=='macos' and meta.get('target_arch')=='aarch64');check('actual-core-version',meta.get('version') in ['v0.4.2','0.4.2'])
    initial=get('/state');check('initial-waiting-state',initial.get('state')=='waiting')
    get('/state/scanning?player=Harbor-QA-Protocol-Only')
    for _ in range(40):
        scanning=get('/state')
        if scanning.get('state')=='host-scanning':break
        time.sleep(.1)
    check('actual-LAN-scanner-starts',scanning.get('state')=='host-scanning')
    check('monotonic-state-index',scanning.get('index',0)>initial.get('index',0))
    get('/state/ide')
    for _ in range(40):
        stopped=get('/state')
        if stopped.get('state')=='waiting':break
        time.sleep(.1)
    check('stop-resets-own-core',stopped.get('state')=='waiting')
    listening=subprocess.run(['/usr/sbin/lsof','-nP','-iTCP:'+str(port),'-sTCP:LISTEN'],capture_output=True,text=True).stdout
    check('control-API-loopback-only','127.0.0.1:'+str(port) in listening and '*:'+str(port) not in listening)
finally:
    if process and process.poll() is None:
        process.terminate()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill();process.wait()
    if process:check('owned-core-process-exits',process.poll() is not None)
    report=dict(passed=sum(checks.values()),failed=sum(not x for x in checks.values()),checks=checks,twoExternalNetworksTested=False,realMinecraftGameLaunched=False)
    (root/'evidence/terracotta-core-report.json').write_text(json.dumps(report,indent=2))
assert all(checks.values())
