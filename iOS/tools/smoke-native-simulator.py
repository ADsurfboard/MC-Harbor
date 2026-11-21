#!/usr/bin/env python3
"""Cold-launch the complete native App on a dedicated disposable simulator.

No JVM/gameplay claim is made. Neither shared UI-test devices nor real accounts
are modified. Cleanup diagnostics must never mask the original failure.
"""
import json, os, plistlib, re, shutil, subprocess, time, uuid, zipfile, runpy
from pathlib import Path
from simulator_recording import run_recorded_tests

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build/MC-Harbor-simulator.app'
OUT = ROOT / 'evidence/native-simulator-smoke'
OUT.mkdir(parents=True, exist_ok=True)
REPORT = OUT / 'result.json'
report = {'kind': 'complete-native-app-cold-launch', 'passed': False,
          'minecraftGameplayVerified': False, 'cleanupErrors': []}
udid = None
home = None
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
    report['hostMemoryBefore'] = subprocess.check_output(['sysctl', 'vm.swapusage'], text=True, timeout=10).strip()
    info = plistlib.loads((APP / 'Info.plist').read_bytes())
    bundle = info['CFBundleIdentifier']
    assert bundle == 'net.morben.harbor.ios'
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '--json'], timeout=30))
    report['bootedDevicesBefore'] = [d['name'] for group in inventory['devices'].values() for d in group if d['state'] == 'Booted']
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        assert not report['bootedDevicesBefore'], 'Release UI-test simulator clones before booting the native-app device'
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
    # The complete bundle includes four signed JVMs, unlike the small UI host.
    # Hosted-runner first-install work must have its own bounded budget.
    run(['xcrun', 'simctl', 'install', udid, str(APP)], timeout=300)
    data = Path(run(['xcrun', 'simctl', 'get_app_container', udid, bundle, 'data'], capture_output=True).stdout.strip())
    home = data / 'Library/Application Support/MC-Harbor'
    ready = home / '.native-smoke-ready'
    assert not ready.exists(), 'Cold-launch marker must not preexist'
    # XCTest launches the already-installed app and asserts its first visible
    # screen. A separate simctl launch can stall in CoreSimulator before the
    # XCTest runner starts, even though XCTest can launch the same bundle.
    # Real input files in this freshly-created simulator's private container.
    # No runtime test flag switches archive reading or localization behavior.
    datapack = home / 'instances/default/saves/Harbor Data QA/datapacks/qa.zip'
    datapack.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(datapack, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('pack.mcmeta', json.dumps({'pack': {'pack_format': 15, 'description': 'QA datapack'}}))
        archive.writestr('data/qa/advancements/start.json', json.dumps({'display': {'title': {'text': 'Native ZIP QA title'}}, 'criteria': {'id': {'trigger': 'minecraft:impossible'}}}))
        archive.writestr('data/qa/structure/untouched.nbt', bytes([0, 255, 128, 17, 31, 99, 0]))
    original_datapack = datapack.read_bytes()
    world_fixture = runpy.run_path(str(ROOT / 'tools/native-world-fixture.py'))
    world_file = datapack.parent.parent / 'level.dat'
    original_world = world_fixture['create'](); world_file.write_bytes(original_world)
    report['phase'] = 'native-xctest'
    command = ['xcodebuild', '-project', str(ROOT / 'MCHarborIOS.xcodeproj'), '-scheme', 'HarborNativeRuntimeTests',
         '-destination', 'platform=iOS Simulator,id=' + udid, '-parallel-testing-enabled', 'NO',
         '-maximum-concurrent-test-simulator-destinations', '1', '-derivedDataPath', str(ROOT / 'DerivedData'),
         '-resultBundlePath', str(OUT / 'native-profile.xcresult'), 'CODE_SIGNING_ALLOWED=NO', 'test']
    subprocess.run(command, check=True, timeout=900)
    assert ready.is_file() and ready.read_text() == 'HARBOR_ROOT_READY', 'The complete native app did not reach its SwiftUI root'
    assert (home / 'accounts').is_dir(), 'Private account storage was not initialized'
    assert not (data / 'Documents/accounts').exists(), 'Accounts must not be Files-shared'
    report.update(rootAppeared=True, privateStorage=True)
    with zipfile.ZipFile(datapack) as archive:
        assert archive.testzip() is None
        translated = json.loads(archive.read('data/qa/advancements/start.json'))
        assert translated == {'display': {'title': {'text': 'Localized native ZIP QA'}}, 'criteria': {'id': {'trigger': 'minecraft:impossible'}}}
        assert archive.read('data/qa/structure/untouched.nbt') == bytes([0, 255, 128, 17, 31, 99, 0])
    backups = list((home / 'harbor-localization-backups').glob('*.zip'))
    assert backups, 'Native ZIP datapack application did not create a backup'
    with zipfile.ZipFile(backups[-1]) as archive:
        assert archive.read('saves/Harbor Data QA/datapacks/qa.zip') == original_datapack
    report['realCompressedDatapackTranslationAndBackup'] = True
    edited_world = world_fixture['inspect_fixture'](world_file.read_bytes())
    assert edited_world['LevelName'] == 'Native world edited'
    assert edited_world['Player']['Health'] == 7.5
    assert edited_world['mod_blob'] == world_fixture['OPAQUE']
    backups = list((home / 'harbor-world-backups').glob('*.zip'))
    assert backups, 'Native world editor did not create an original backup'
    with zipfile.ZipFile(backups[-1]) as archive:
        assert archive.read('level.dat') == original_world
    report['realWorldEditingAndBackup'] = True
    report.update(realProfileCancelSaveAndRelaunch=True)
    if os.environ.get('HARBOR_RECORD_SIMULATOR') == '1':
        # XCTest can buffer both case boundaries together. Replay only Files
        # after the full suite, starting the camera before XCTest opens the app.
        case = 'testLocalModpackImportOpensFilesAndCanCancel'
        capture = command.copy()
        capture[capture.index('-resultBundlePath') + 1] = str(ROOT / 'DerivedData' / 'HarborFilesRecording.xcresult')
        capture[-1] = 'test-without-building'
        capture.append('-only-testing:HarborNativeIOSUITests/HarborNativeIOSUITests/' + case)
        record = run_recorded_tests(capture, device=udid, timeout=180,
                                    clips={case: 'iPhone-Native-Modpack-Import'},
                                    directory=ROOT / 'evidence/recordings/native', pre_record=True)
        record.check_returncode()
        report['filesRecordingReplayPassed'] = True
    report['passed'] = True
except Exception as error:
    report['error'] = str(error)
    if isinstance(error, subprocess.CalledProcessError):
        (OUT / 'failed-command.log').write_text((error.stdout or '') + (error.stderr or ''))
    raise
finally:
    # Inspect only CI-created profile identity/display fields, never accounts,
    # tokens, JVM arguments or a developer's local App data.
    if os.environ.get('GITHUB_ACTIONS') == 'true' and home:
        try:
            profiles = home / 'instances/default/launcher_profiles.json'
            if profiles.is_file() and profiles.stat().st_size <= 4 * 1024 * 1024:
                value = json.loads(profiles.read_text())
                entries = value.get('profiles', {})
                summary = {'selected': value.get('selectedProfile'), 'profiles': [
                    {'id': key, 'name': item.get('name')} for key, item in list(entries.items())[:50]
                    if isinstance(item, dict)]}
                (OUT / 'ci-profile-state.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
        except Exception as error:
            report['cleanupErrors'].append('CI profile inspection: ' + type(error).__name__)
    result = OUT / 'native-profile.xcresult'
    if result.is_dir():
        diagnostic('native-ui-summary.json', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                   '--path', str(result)], timeout=60)
        exported = OUT / 'native-ui-attachments'
        diagnostic('attachment-export.log', ['xcrun', 'xcresulttool', 'export', 'attachments',
                   '--path', str(result), '--output-path', str(exported)], timeout=60)
        # The original recording remains in xcresult; avoid uploading a second copy.
        for movie in exported.glob('*.mp4'):
            movie.unlink()
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
        if os.environ.get('GITHUB_ACTIONS') == 'true':
            diagnostic('shutdown-test-clones.log', ['xcrun', 'simctl', 'shutdown', 'all'], timeout=90)
        diagnostic('delete.log', ['xcrun', 'simctl', 'delete', udid])
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2))
