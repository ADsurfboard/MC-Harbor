"""Verify that a launcher exit leaves the owned game alive and recoverable."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

root = Path(__file__).resolve().parents[1]
bundled = root / 'build/MC Harbor.app/Contents/Resources'
jdk = Path(os.environ.get('JAVA_HOME') or subprocess.check_output(
    ['/usr/libexec/java_home', '-v', '21'], text=True).strip())
class_path = os.pathsep.join(str(bundled / name) for name in ('Backend.jar', 'HMCLCore.jar'))

with tempfile.TemporaryDirectory(prefix='harbor-game-lifecycle-') as folder:
    scratch = Path(folder)
    run_directory = scratch / 'instance'
    run_directory.mkdir()
    control_directory = scratch / 'launch-control'
    marker = control_directory / f'{uuid.uuid4()}.stop'
    receipt = marker.with_suffix('.running')
    fixture = scratch / 'LifecycleFixture.java'
    fixture.write_text('''
package net.morben.shenggan;
import java.nio.file.*;
import java.util.List;
import org.jackhuang.hmcl.util.platform.ManagedProcess;
public final class LifecycleFixture {
    public static void main(String[] args) throws Exception {
        try (NativeGameControl control = new NativeGameControl(Path.of(args[0]), Path.of(args[1]), args[2])) {
            if (args.length != 3) throw new AssertionError("A second owner acquired the same directory");
            control.checkPendingStop();
            Process child = new ProcessBuilder("/bin/sleep", "35").start();
            try {
                var buffered = new ManagedProcess(child, List.of("/bin/sleep", "35"));
                for (int i = 0; i < 2048; i++) buffered.addLine(i + " " + "X".repeat(8192));
                var lines = buffered.getLines(null);
                if (lines.size() != 256 || !lines.get(0).startsWith("1792 ") ||
                    !lines.get(lines.size() - 1).startsWith("2047 ") || lines.get(lines.size() - 1).length() != 4096)
                    throw new AssertionError("Native game log buffer is not bounded");
                control.record("isolated", child);
                System.out.println(child.pid());
                control.waitFor(child);
            } finally {
                if (child.isAlive()) child.destroy();
                Files.writeString(Path.of(args[0]).resolve("completed"), "stopped");
            }
        }
    }
}
''')
    subprocess.run([jdk/'bin/javac', '-cp', class_path, '-d', scratch, fixture], check=True)
    java = ['/usr/bin/nohup', str(bundled/'Runtime/bin/java'), '-cp',
            class_path + os.pathsep + str(scratch), 'net.morben.shenggan.LifecycleFixture',
            str(scratch), str(run_directory), str(marker)]
    invoker = scratch/'controller.py'
    invoker.write_text('''
import subprocess, sys
child = subprocess.Popen(sys.argv[1:], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert int(child.stdout.readline()) > 1
child.stdout.close()
child.stderr.close()
''')
    try:
        subprocess.run([os.environ.get('PYTHON', 'python3'), invoker, *java], check=True, timeout=15)
        running = json.loads(receipt.read_text())
        assert running['id'] == 'isolated'
        os.kill(running['pid'], 0)
        print('Game remained alive after the launcher-side process exited.')
        overlapping = subprocess.run([*java[:-1], str(control_directory / f'{uuid.uuid4()}.stop'), 'duplicate'],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=12, text=True)
        assert overlapping.returncode and '已有实例' in overlapping.stderr
        verifier = scratch / 'main.swift'
        verifier.write_text(r"""
import Foundation
struct GameInstance { let id: String; let runDirectory: String }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fixture = GameInstance(id: "isolated", runDirectory: CommandLine.arguments[2])
let wrong = GameInstance(id: "isolated", runDirectory: directory.appendingPathComponent("wrong").path)
let expected = URL(fileURLWithPath: CommandLine.arguments[3])
let restored = HarborGameReceipts.controls(for: [fixture], in: directory)["isolated"]
func folder(_ url: URL?) -> String? { url?.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path }
precondition(restored?.lastPathComponent == expected.lastPathComponent && folder(restored) == folder(expected),
             "Restored marker: \(String(describing: restored?.path))")
precondition(HarborGameReceipts.controls(for: [wrong], in: directory).isEmpty)
""")
        binary = scratch / 'receipt-verification'
        subprocess.run(['swiftc', str(root/'Sources/GameReceipts.swift'), verifier, '-o', binary], check=True)
        subprocess.run([binary, scratch, run_directory, marker], check=True, timeout=5)
        marker.touch()
        deadline = time.monotonic() + 8
        while not (scratch/'completed').exists() or receipt.exists():
            assert time.monotonic() < deadline, 'The exact game did not stop or the receipt was retained'
            time.sleep(.1)
    finally:
        if receipt.exists():
            marker.touch()
            # Let the owner release the files before the isolated directory disappears.
            for _ in range(30):
                if not receipt.exists(): break
                time.sleep(.1)

# Keep the real protocol bridge in this test. The fixture keeps its output
# open after a short launch event until the client acknowledges the event.
with tempfile.TemporaryDirectory(prefix='harbor-bridge-stream-') as folder:
    scratch = Path(folder)
    resources = scratch/'Runtime/bin'
    resources.mkdir(parents=True)
    fixture = resources/'java'
    fixture.write_text(r'''#!/bin/sh
/bin/cat >/dev/null
printf '%s\n' '{"event":"launched","pid":42}'
for ignored in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if test -f "$HARBOR_BRIDGE_STREAM_QA/acknowledged"; then
        printf '%s\n' '{"event":"result","data":{"acknowledged":true}}'
        exit 0
    fi
    /bin/sleep 0.2
done
exit 2
''')
    fixture.chmod(0o700)
    entry = scratch/'main.swift'
    bridge=(root/'Sources/AppModel.swift').read_text().split('enum JavaBridge {',1)[1]
    entry.write_text(r'''
import Foundation
import Darwin
enum NativePaths {
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HARBOR_BRIDGE_STREAM_QA"]!, isDirectory: true)
    static let resources = root
}
let done = DispatchSemaphore(value: 0)
let process = try JavaBridge.start(input: ["command": "launch"], event: { event in
    guard event["event"] as? String == "launched" else { return }
    try? Data().write(to: NativePaths.root.appendingPathComponent("acknowledged"), options: .atomic)
}, completion: { result in
    guard case .success(let value) = result, value["acknowledged"] as? Bool == true else { exit(1) }
    done.signal()
})
let deadline = DispatchTime.now() + 8
// Process's termination callback may use the main queue on older Foundation.
var completed = false
while DispatchTime.now() < deadline {
    if done.wait(timeout: .now()) == .success {
        completed = true
        break
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
}
guard completed, FileManager.default.fileExists(atPath: NativePaths.root.appendingPathComponent("acknowledged").path),
      !process.isRunning, process.terminationStatus == 0 else { exit(1) }
'''.replace('let done =', 'enum JavaBridge {'+bridge+'\nlet done =',1))
    binary=scratch/'bridge-stream-check'
    subprocess.run(['swiftc',entry,'-o',binary],check=True)
    subprocess.run([binary],env=dict(os.environ,HARBOR_BRIDGE_STREAM_QA=folder),check=True,timeout=16)
    print('A short launch event reached the client before the helper exited.')

report = root/'evidence/game-lifecycle-report.json'
report.parent.mkdir(exist_ok=True)
report.write_text(json.dumps({'runsAfterLauncherExit': True, 'rejectsConcurrentOwner':True, 'boundedLogBuffer': True, 'liveLaunchEvent': True,
    'reconnectsMatchingPIDAndDirectory':True, 'stopsWithMarkerAndClearsReceipt':True},indent=2))
print('Game session persists, reconnects, rejects a duplicate owner and stops correctly.')
