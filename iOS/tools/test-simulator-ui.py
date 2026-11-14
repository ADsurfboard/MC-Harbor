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
def device_inventory(device_set=None):
 command=['xcrun','simctl']+(['--set',device_set] if device_set else [])
 result=subprocess.run(command+['list','devices','--json'],capture_output=True,text=True,timeout=30)
 # Xcode maintains a separate test-clone device set. On a clean runner it
 # need not exist yet; other inventory errors remain real failures.
 if result.returncode and device_set=='testing' and not (Path.home()/'Library/Developer/XCTestDevices').exists():return []
 result.check_returncode()
 return [dict(d,deviceSet=device_set) for group in json.loads(result.stdout)['devices'].values() for d in group]
def booted_devices():
 return [{'name':d['name'],'udid':d['udid'],'deviceSet':d['deviceSet']} for d in device_inventory()+device_inventory('testing') if d['state']=='Booted']
def shutdown_ci_devices():
 run(['xcrun','simctl','shutdown','all'],timeout=120)
 if (Path.home()/'Library/Developer/XCTestDevices').exists():run(['xcrun','simctl','--set','testing','shutdown','all'],timeout=120)
for family,device_type,runtime in choices:
 # A fresh owned simulator avoids previous runner state without erasing any
 # user's device. Explicit bootstatus and a cold preflight keep first-boot OS
 # migration outside XCTest's shorter app-launch progress deadline.
 # XCTest may create its own simulator clone even with one destination. Only
 # on an ephemeral CI machine may we release all such devices between families.
 # Local runs continue to own just the UUID created below.
 before=booted_devices()
 if os.environ.get('GITHUB_ACTIONS')=='true':
  shutdown_ci_devices()
  assert not booted_devices(),'CI simulator clones were not released'
 device_name='Harbor UI '+family+' '+str(uuid.uuid4())[:8]
 device=subprocess.check_output(['xcrun','simctl','create',device_name,device_type,runtime],text=True,timeout=60).strip()
 result=EVIDENCE/('ui-'+family+'.xcresult')
 status={'family':family,'device':device,'runtime':runtime,'resultBundle':str(result),'passed':False,'bootedDevicesBefore':before,'cleanupErrors':[]}
 status['hostMemoryBefore']=subprocess.check_output(['sysctl','vm.swapusage'],text=True,timeout=10).strip()
 phase='boot';started=time.monotonic();completed=None
 try:
  run(['xcrun','simctl','boot',device],timeout=60)
  run(['xcrun','simctl','bootstatus',device,'-b'],timeout=300)
  # XCTest owns installation and cold launch. Querying an app container before
  # XCTest can time out while a fresh OS is still registering its services.
  # This UUID has just been created, so it cannot contain an earlier run's
  # marker. Check the actual marker after all UI assertions, including clones.
  phase='xctest-cold-launch'
  completed=subprocess.run(['xcodebuild','-project','MCHarborIOS.xcodeproj','-scheme','HarborIOSHarness','-destination','platform=iOS Simulator,id='+device,'-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1','-derivedDataPath','DerivedData','-resultBundlePath',str(result),'CODE_SIGNING_ALLOWED=NO','test'],cwd=ROOT,timeout=900)
  # Xcode may reinstall into a new data container or run on its own clone.
  # Resolve after XCTest, and inspect only this run's uniquely named devices.
  candidates=[d for d in device_inventory()+device_inventory('testing') if d['udid']==device or device_name in d['name']]
  status['rootAppeared']=False
  status['rootCandidates']=[{'name':d['name'],'udid':d['udid'],'deviceSet':d['deviceSet']} for d in candidates]
  for candidate in candidates:
   command=['xcrun','simctl']+(['--set',candidate['deviceSet']] if candidate['deviceSet'] else [])
   located=subprocess.run(command+['get_app_container',candidate['udid'],'net.morben.harbor.ios.qa','data'],capture_output=True,text=True,timeout=120)
   if located.returncode:continue
   current=Path(located.stdout.strip())/'Library/Application Support/NativeUITest/.native-smoke-ready'
   if current.is_file() and current.read_text()=='HARBOR_ROOT_READY':
    status.update(rootAppeared=True,rootDevice=candidate['udid'],rootDeviceSet=candidate['deviceSet'],rootDeviceCloned=candidate['udid']!=device or candidate['deviceSet'] is not None)
    break
  status['passed']=completed.returncode==0 and status['rootAppeared']
  if completed.returncode==0:assert status['rootAppeared'],'Real UI tests did not create the shared-root marker'
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
   if os.environ.get('GITHUB_ACTIONS')=='true':
    commands.insert(0,['xcrun','simctl','shutdown','all'])
    if (Path.home()/'Library/Developer/XCTestDevices').exists():commands.insert(0,['xcrun','simctl','--set','testing','shutdown','all'])
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
