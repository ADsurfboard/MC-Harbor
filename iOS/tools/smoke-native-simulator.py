#!/usr/bin/env python3
"""Cold-launch the complete native App on a dedicated disposable simulator.

No JVM/gameplay claim is made. Neither shared UI-test devices nor real accounts
are modified. Cleanup diagnostics must never mask the original failure.
"""
import json, os, plistlib, re, shutil, subprocess, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build/MC-Harbor-simulator.app'
OUT = ROOT / 'evidence/native-simulator-smoke'
OUT.mkdir(parents=True, exist_ok=True)
REPORT = OUT / 'result.json'
report = {'kind': 'complete-native-app-cold-launch', 'passed': False,
          'minecraftGameplayVerified': False, 'cleanupErrors': []}
udid = None
started = time.time()

def run(arguments, timeout=90, **kwargs):
    report['phase'] = arguments[2] if len(arguments) > 2 else arguments[0]
    return subprocess.run(arguments, check=True, text=True, timeout=timeout, **kwargs)

def diagnostic(name, arguments, timeout=25):
    try:
        result = subprocess.run(arguments, text=True, capture_output=True, timeout=timeout)
        (OUT / name).write_text((result.stdout + result.stderr)[-5 * 1024 * 1024:])
    except Exception as error:
        report['cleanupErrors'].append(name + ': ' + str(error))

try:
    info = plistlib.loads((APP / 'Info.plist').read_bytes())
    bundle = info['CFBundleIdentifier']
    assert bundle == 'net.morben.harbor.ios'
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '--json'], timeout=30))
    runtime = next(r for r in reversed(inventory['runtimes']) if r.get('isAvailable') and '.iOS-' in r['identifier'])
    compatible = next(d for d in inventory['devices'][runtime['identifier']]
                      if d.get('isAvailable') and d['name'].startswith('iPhone'))
    device_type = next(d for d in inventory['devicetypes'] if d['name'] == compatible['name'])
    udid = run(['xcrun', 'simctl', 'create', 'Harbor Native Smoke ' + uuid.uuid4().hex[:8],
                device_type['identifier'], runtime['identifier']], capture_output=True).stdout.strip()
    assert re.fullmatch(r'[0-9A-Fa-f-]{36}', udid), 'Invalid disposable simulator identifier'
    report.update(device=device_type['name'], runtime=runtime['identifier'], bundle=bundle, udid=udid)
    run(['xcrun', 'simctl', 'boot', udid])
    run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], timeout=180)
    run(['xcrun', 'simctl', 'install', udid, str(APP)])
    data = Path(run(['xcrun', 'simctl', 'get_app_container', udid, bundle, 'data'], capture_output=True).stdout.strip())
    home = data / 'Library/Application Support/MC-Harbor'
    ready = home / '.native-smoke-ready'
    assert not ready.exists(), 'Cold-launch marker must not preexist'
    env = os.environ.copy()
    env.update(SIMCTL_CHILD_LOG_TO_CONSOLE='1', SIMCTL_CHILD_HARBOR_SMOKE_TEST='1')
    # Do not pass host paths as --stdout/--stderr. The simulator launch service
    # may block trying to open them in the application sandbox.
    output = run(['xcrun', 'simctl', 'launch', udid, bundle], env=env, capture_output=True)
    (OUT / 'launch.log').write_text(output.stdout + output.stderr)
    match = re.search(r':\s*(\d+)\s*$', output.stdout.strip())
    assert match, 'No native app PID returned'
    pid = int(match[1])
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        os.kill(pid, 0)
        if ready.exists() and ready.read_text() == 'HARBOR_ROOT_READY':
            break
        time.sleep(0.5)
    else:
        raise AssertionError('The complete native app did not reach its SwiftUI root')
    time.sleep(3)
    os.kill(pid, 0)
    run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(OUT / 'native-app-portrait.png')])
    assert home.is_dir(), 'Private Application Support storage was not created'
    assert (home / 'accounts').is_dir(), 'Account storage was not initialized'
    assert not (data / 'Documents/accounts').exists(), 'Accounts must not be Files-shared'
    report.update(rootAppeared=True, privateStorage=True, pid=pid)
    run(['xcodebuild', '-project', str(ROOT / 'MCHarborIOS.xcodeproj'), '-scheme', 'HarborNativeRuntimeTests',
         '-destination', 'platform=iOS Simulator,id=' + udid, '-derivedDataPath', str(ROOT / 'DerivedData'),
         '-resultBundlePath', str(OUT / 'native-profile.xcresult'), 'CODE_SIGNING_ALLOWED=NO', 'test'], timeout=360)
    report.update(passed=True, realProfileCancelSaveAndRelaunch=True)
except Exception as error:
    report['error'] = str(error)
    if isinstance(error, subprocess.CalledProcessError):
        (OUT / 'failed-command.log').write_text((error.stdout or '') + (error.stderr or ''))
    raise
finally:
    if udid:
        diagnostic('native-unified.log', ['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--last', '3m',
                   '--style', 'compact', '--predicate', 'process == "AngelAuraAmethyst" OR eventMessage CONTAINS "net.morben.harbor.ios"'])
        if not report['passed']:
            diagnostic('screenshot-command.log', ['xcrun', 'simctl', 'io', udid, 'screenshot', str(OUT / 'native-app-failure.png')])
            for crash in (Path.home() / 'Library/Logs/DiagnosticReports').glob('AngelAuraAmethyst*'):
                if crash.is_file() and crash.stat().st_mtime >= started - 3:
                    shutil.copy2(crash, OUT / crash.name)
        diagnostic('terminate.log', ['xcrun', 'simctl', 'terminate', udid, 'net.morben.harbor.ios'])
        diagnostic('shutdown.log', ['xcrun', 'simctl', 'shutdown', udid], timeout=45)
        diagnostic('delete.log', ['xcrun', 'simctl', 'delete', udid])
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2))
