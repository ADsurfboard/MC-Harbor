#!/usr/bin/env python3
"""Install and cold-launch the complete native app, never the UI test harness.

This verifies process/UI startup and private storage. It does not assert that
Minecraft, a JVM, JIT or game rendering has been exercised.
"""
import json, os, plistlib, re, subprocess, time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/'build/MC-Harbor-simulator.app'
OUT=ROOT/'evidence/native-simulator-smoke';OUT.mkdir(parents=True,exist_ok=True)
REPORT=OUT/'result.json'
report={'kind':'complete-native-app-cold-launch','passed':False,'minecraftGameplayVerified':False}
device=None;booted_here=False;pid=None
def run(arguments,**kwargs):
    return subprocess.run(arguments,check=True,text=True,timeout=90,**kwargs)
try:
    info=plistlib.loads((APP/'Info.plist').read_bytes())
    bundle=info['CFBundleIdentifier'];assert bundle=='net.morben.harbor.ios'
    devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','--json']))['devices']
    for runtime,items in reversed(list(devices.items())):
        if 'iOS' not in runtime:continue
        device=next((item for item in items if item['name'].startswith('iPhone')),None)
        if device:break
    assert device,'An actual iPhone simulator runtime is required'
    udid=device['udid'];report.update(device=device['name'],runtime=runtime,bundle=bundle)
    if device['state']!='Booted':run(['xcrun','simctl','boot',udid]);booted_here=True
    run(['xcrun','simctl','bootstatus',udid,'-b'])
    run(['xcrun','simctl','install',udid,str(APP)])
    env=os.environ.copy();env.update(SIMCTL_CHILD_LOG_TO_CONSOLE='1',SIMCTL_CHILD_HARBOR_SMOKE_TEST='1')
    output=run(['xcrun','simctl','launch','--terminate-running-process','--stdout='+str(OUT/'stdout.log'),'--stderr='+str(OUT/'stderr.log'),udid,bundle],env=env,capture_output=True)
    (OUT/'launch.log').write_text(output.stdout+output.stderr)
    match=re.search(r':\s*(\d+)\s*$',output.stdout.strip());assert match,'No native app PID returned'
    pid=int(match[1]);assert pid>1
    deadline=time.monotonic()+60
    while time.monotonic()<deadline:
        os.kill(pid,0)
        log='\n'.join(p.read_text(errors='replace') for p in OUT.glob('*.log'))
        if 'HARBOR_ROOT_READY' in log:break
        time.sleep(0.5)
    else:raise AssertionError('The real native app did not reach its SwiftUI root')
    time.sleep(3);os.kill(pid,0)
    run(['xcrun','simctl','io',udid,'screenshot',str(OUT/'native-app-portrait.png')])
    data=Path(run(['xcrun','simctl','get_app_container',udid,bundle,'data'],capture_output=True).stdout.strip())
    home=data/'Library/Application Support/MC-Harbor'
    assert home.is_dir(),'Private Application Support storage was not created'
    assert (home/'accounts').is_dir(),'Account storage was not initialized'
    assert not (data/'Documents/accounts').exists(),'Accounts must not be in Files-sharing Documents'
    report.update(passed=True,rootAppeared=True,privateStorage=True,pid=pid)
except Exception as error:
    report['error']=str(error)
    raise
finally:
    REPORT.write_text(json.dumps(report,ensure_ascii=False,indent=2))
    if device:
        subprocess.run(['xcrun','simctl','terminate',device['udid'],'net.morben.harbor.ios'],capture_output=True,timeout=30)
        if booted_here:subprocess.run(['xcrun','simctl','shutdown',device['udid']],capture_output=True,timeout=30)
