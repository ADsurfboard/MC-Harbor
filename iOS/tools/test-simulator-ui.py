#!/usr/bin/env python3
"""Run the native app UI on disposable iPhone and iPad simulators."""
import subprocess,json,uuid,time,os
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; EVIDENCE=ROOT/'evidence'; EVIDENCE.mkdir(exist_ok=True)
def run(args,**kwargs): return subprocess.run(args,check=True,**kwargs)
all_devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','--json']))['devices']
runtimes=json.loads(subprocess.check_output(['xcrun','simctl','list','runtimes','--json']))['runtimes']
runtimes=sorted((r for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier']),
                key=lambda r:tuple(int(v) for v in r['version'].split('.')),reverse=True)
choices=[]
for family in ['iPhone','iPad']:
 for runtime in runtimes:
  devices=all_devices.get(runtime['identifier'],[])
  found=next((d for d in devices if d['name'].startswith(family)),None)
  if found:choices.append((family,found['deviceTypeIdentifier'],runtime['identifier']));break
assert len(choices)==2,'Both iPhone and iPad simulator runtimes are required'
def booted_devices():
 inventory=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','--json'],timeout=30))
 return [{'name':d['name'],'udid':d['udid']} for group in inventory['devices'].values() for d in group if d['state']=='Booted']
for family,device_type,runtime in choices:
 # A fresh owned simulator avoids previous runner state without erasing any
 # user's device. Explicit bootstatus and a cold preflight keep first-boot OS
 # migration outside XCTest's shorter app-launch progress deadline.
 # XCTest may create its own simulator clone even with one destination. Only
 # on an ephemeral CI machine may we release all such devices between families.
 # Local runs continue to own just the UUID created below.
 before=booted_devices()
 if os.environ.get('GITHUB_ACTIONS')=='true':
  run(['xcrun','simctl','shutdown','all'],timeout=120)
  assert not booted_devices(),'CI simulator clones were not released'
 device=subprocess.check_output(['xcrun','simctl','create','Harbor UI '+family+' '+str(uuid.uuid4())[:8],device_type,runtime],text=True,timeout=60).strip()
 result=EVIDENCE/('ui-'+family+'.xcresult')
 status={'family':family,'device':device,'runtime':runtime,'resultBundle':str(result),'passed':False,'bootedDevicesBefore':before,'cleanupErrors':[]}
 status['hostMemoryBefore']=subprocess.check_output(['sysctl','vm.swapusage'],text=True,timeout=10).strip()
 phase='boot';started=time.monotonic();completed=None
 try:
  run(['xcrun','simctl','boot',device],timeout=60)
  run(['xcrun','simctl','bootstatus',device,'-b'],timeout=300)
  phase='install-preflight'
  run(['xcrun','simctl','install',device,str(ROOT/'DerivedData/Build/Products/Debug-iphonesimulator/HarborIOSHarness.app')],timeout=300)
  phase='launch-preflight'
  container=Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,'net.morben.harbor.ios.qa','data'],text=True,timeout=30).strip())
  ready=container/'Library/Application Support/NativeUITest/.native-smoke-ready'
  assert not ready.exists(),'A fresh preflight marker must not already exist'
  environment=os.environ.copy();environment['SIMCTL_CHILD_HARBOR_SMOKE_TEST']='1'
  run(['xcrun','simctl','launch',device,'net.morben.harbor.ios.qa'],env=environment,timeout=120)
  # simctl launch returns a PID before UIKit finishes its first scene. Sending
  # terminate immediately races SpringBoard's launch assertion on fresh iPads.
  # Wait for the actual shared root instead of assuming PID means UI readiness.
  deadline=time.monotonic()+120
  while time.monotonic()<deadline:
   if ready.is_file() and ready.read_text()=='HARBOR_ROOT_READY':break
   time.sleep(0.25)
  else:raise TimeoutError('UI preflight did not reach the actual SwiftUI root')
  status['rootAppeared']=True
  run(['xcrun','simctl','terminate',device,'net.morben.harbor.ios.qa'],timeout=90)
  status['preflightPassed']=True;phase='xctest'
  completed=subprocess.run(['xcodebuild','-project','MCHarborIOS.xcodeproj','-scheme','HarborIOSHarness','-destination','platform=iOS Simulator,id='+device,'-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1','-derivedDataPath','DerivedData','-resultBundlePath',str(result),'CODE_SIGNING_ALLOWED=NO','test'],cwd=ROOT,timeout=900)
  status['passed']=completed.returncode==0
 except Exception as error:
  status['error']=str(error);raise
 finally:
  status.update(phase=phase,elapsedSeconds=round(time.monotonic()-started,2))
  (EVIDENCE/('ui-'+family+'.json')).write_text(json.dumps(status,indent=2))
  try:
   output=EVIDENCE/'screenshots'/family;output.mkdir(parents=True,exist_ok=True)
   if result.exists():run(['xcrun','xcresulttool','export','attachments','--path',str(result),'--output-path',str(output)],timeout=120)
   if not status['passed']:
    with (EVIDENCE/('ui-'+family+'-system.log')).open('w') as log:
     subprocess.run(['xcrun','simctl','spawn',device,'log','show','--last','15m','--style','compact','--predicate','process == "HarborIOSHarness" OR process == "SpringBoard"'],stdout=log,stderr=subprocess.STDOUT,timeout=60)
  finally:
   # Only delete this script's UUID. Never shut down a local user's simulators.
   commands=[['xcrun','simctl','shutdown',device],['xcrun','simctl','delete',device]]
   if os.environ.get('GITHUB_ACTIONS')=='true':commands.insert(0,['xcrun','simctl','shutdown','all'])
   for command in commands:
    try:
     cleanup=subprocess.run(command,capture_output=True,text=True,timeout=120)
     if cleanup.returncode and command[2]!='shutdown':status['cleanupErrors'].append(' '.join(command)+': '+cleanup.stderr[-1000:])
    except Exception as error:status['cleanupErrors'].append(str(error))
   try:
    status['bootedDevicesAfter']=booted_devices()
    status['hostMemoryAfter']=subprocess.check_output(['sysctl','vm.swapusage'],text=True,timeout=10).strip()
   except Exception as error:status['cleanupErrors'].append('Inventory: '+str(error))
   (EVIDENCE/('ui-'+family+'.json')).write_text(json.dumps(status,indent=2))
 if completed.returncode:raise SystemExit(completed.returncode)
