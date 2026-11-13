#!/usr/bin/env python3
"""Run the native app UI on disposable iPhone and iPad simulators."""
import subprocess,json,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; EVIDENCE=ROOT/'evidence'; EVIDENCE.mkdir(exist_ok=True)
def run(args,**kwargs): return subprocess.run(args,check=True,**kwargs)
all_devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','--json']))['devices']
choices=[]
for family in ['iPhone','iPad']:
 for runtime,devices in reversed(list(all_devices.items())):
  if 'iOS' not in runtime:continue
  found=next((d for d in devices if d['name'].startswith(family)),None)
  if found:choices.append((family,found['udid']));break
assert len(choices)==2,'Both iPhone and iPad simulator runtimes are required'
for family,device in choices:
 result=EVIDENCE/('ui-'+family+'.xcresult')
 try:
  completed=subprocess.run(['xcodebuild','-project','MCHarborIOS.xcodeproj','-scheme','HarborIOSHarness','-destination','platform=iOS Simulator,id='+device,'-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1','-derivedDataPath','DerivedData','-resultBundlePath',str(result),'CODE_SIGNING_ALLOWED=NO','test'],cwd=ROOT)
 finally:
  # These are disposable hosted-runner devices. Release each before the next
  # family/native smoke run instead of leaving multiple iOS VMs booted.
  if __import__('os').environ.get('GITHUB_ACTIONS')=='true':
   # Xcode may launch a cloned test device instead of the destination UDID.
   # Only this ephemeral GitHub VM owns all of these devices, never a user's Mac.
   subprocess.run(['xcrun','simctl','list','devices','booted','--json'],check=True,timeout=30)
   subprocess.run(['xcrun','simctl','shutdown','all'],capture_output=True,check=True,timeout=90)
 (EVIDENCE/('ui-'+family+'.json')).write_text(json.dumps({'family':family,'device':device,'resultBundle':str(result),'passed':completed.returncode==0},indent=2))
 output=EVIDENCE/'screenshots'/family;output.mkdir(parents=True,exist_ok=True)
 run(['xcrun','xcresulttool','export','attachments','--path',str(result),'--output-path',str(output)])
 if completed.returncode:raise SystemExit(completed.returncode)
