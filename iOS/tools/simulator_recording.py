"""Record selected real XCTest cases from the disposable simulator display."""
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time

TEST_EVENT = re.compile(r"Test Case '-\[[^ ]+ (\w+)\]' (started|passed|failed|skipped)\b")
CLIP_LIMIT_SECONDS = 90
CLIP_LIMIT_BYTES = 60 * 1024 * 1024


def run_recorded_tests(command, *, device, clips, directory, timeout, cwd=None, pre_record=False):
    if os.environ.get('HARBOR_RECORD_SIMULATOR') != '1':
        return subprocess.run(command, cwd=cwd, timeout=timeout)

    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    outcomes = {}
    active = None
    clip = None
    deadline = time.monotonic() + timeout

    def stop_recording():
        nonlocal active, clip
        if active is None:
            return
        try:
            if active.poll() is None:
                active.send_signal(signal.SIGINT)
            active.wait(timeout=10)
        except subprocess.TimeoutExpired:
            active.kill()
            active.wait(timeout=5)
        finally:
            active = None
        path = directory / clip['file']
        size = path.stat().st_size if path.is_file() else 0
        clip['bytes'] = size
        if not 1024 <= size <= CLIP_LIMIT_BYTES:
            path.unlink(missing_ok=True)
            clip['error'] = f'Invalid recorded size: {size}'
        clip = None

    def start_recording(test):
        nonlocal active, clip
        file_name = clips[test] + '.mp4'
        clip = {'file': file_name, 'test': test, 'started': time.monotonic()}
        outcomes[test] = clip
        path = directory / file_name
        with path.with_suffix('.log').open('w') as diagnostics:
            try:
                active = subprocess.Popen(
                    ['xcrun', 'simctl', 'io', device, 'recordVideo', '--codec=h264', '--force', str(path)],
                    stdout=diagnostics, stderr=subprocess.STDOUT, start_new_session=True,
                )
            except OSError as error:
                clip['error'] = str(error)
                clip = None

    def show_line(line):
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()
        match = TEST_EVENT.search(line.decode('utf-8', errors='replace'))
        if not match or match[1] not in clips:
            return
        test, event = match.groups()
        if event != 'started':
            outcomes.setdefault(test, {})['status'] = event
            if clip and clip['test'] == test:
                stop_recording()
        elif test not in outcomes:
            stop_recording()
            start_recording(test)

    if pre_record and len(clips) != 1:
        raise ValueError('Early video capture requires exactly one test case')
    process = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    buffer = b''
    try:
        if pre_record:
            start_recording(next(iter(clips)))
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                if clip and time.monotonic() - clip['started'] >= CLIP_LIMIT_SECONDS:
                    clip['limitedAtSeconds'] = CLIP_LIMIT_SECONDS
                    stop_recording()
                if not selector.select(timeout=min(1, remaining)):
                    continue
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    if buffer:
                        show_line(buffer)
                    break
                records = (buffer + chunk).splitlines(keepends=True)
                buffer = records.pop() if records and not records[-1].endswith(b'\n') else b''
                for record in records:
                    show_line(record)
        return subprocess.CompletedProcess(command, process.wait(timeout=max(1, deadline - time.monotonic())))
    finally:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=10)
        process.stdout.close()
        stop_recording()
        for result in outcomes.values():
            result.pop('started', None)
        (directory / 'clips.json').write_text(
            json.dumps({'device': device, 'requested': clips, 'recorded': outcomes}, indent=2) + '\n')


def verify_recordings(directory):
    directory = Path(directory)
    manifest = json.loads((directory / 'clips.json').read_text())
    for test, basename in manifest['requested'].items():
        record = manifest['recorded'].get(test, {})
        path = directory / (basename + '.mp4')
        if record.get('status') != 'passed' or record.get('error') or not path.is_file():
            raise SystemExit(f'{basename}: recording or test incomplete: {record}')
        with path.open('rb') as movie:
            header = movie.read(12)
        if header[4:8] != b'ftyp' or path.stat().st_size != record['bytes']:
            raise SystemExit(f'{basename}: invalid MP4 container')
        print(f'{basename}: {record["bytes"]} bytes from {test}')
    if directory.name in {'iPhone', 'iPad'}:
        path = directory.parent.parent / ('ui-' + directory.name + '.json')
        device = json.loads(path.read_text())
        if manifest['device'] != device['rootDevice']:
            raise SystemExit(f'{directory.name}: XCTest used a different device from the recording')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit('Supply the recording directories to validate')
    for recording in sys.argv[1:]:
        verify_recordings(recording)
