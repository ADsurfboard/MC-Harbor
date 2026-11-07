from pathlib import Path
import subprocess
root=Path(__file__).resolve().parent.parent
source=(root/'Sources/InstanceDeletion.swift').read_text().split('\nextension LauncherModel')[0]
fixture=root/'build/QA-InstanceDeletion.swift';fixture.write_text(source)
binary=root/'build/instance-deletion-checks'
subprocess.run(['swiftc','-target','x86_64-apple-macos12.0',str(fixture),str(root/'tools/InstanceDeletionChecks.swift'),'-o',str(binary)],check=True)
subprocess.run([str(binary)],check=True,timeout=60)
