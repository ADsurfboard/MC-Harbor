"""Build MC harbor on Apple Silicon with Xcode tools and a JDK 21."""
from pathlib import Path
import os, shutil, subprocess

root=Path(__file__).resolve().parent.parent
build=root/'build';build.mkdir(exist_ok=True)
subprocess.run(['swiftc','-swift-version','5','-O','-whole-module-optimization','-target','arm64-apple-macos26.0',*[str(p) for p in sorted((root/'Sources').glob('*.swift'))],'-o',str(build/'MCHarbor')],check=True)
subprocess.run(['python3',str(root/'tools/build-backend.py')],check=True)
if not (build/'Runtime').exists():
    jdk=Path(os.environ.get('JAVA_HOME') or subprocess.check_output(['/usr/libexec/java_home','-v','21'],text=True).strip())
    modules='java.base,java.desktop,java.logging,java.management,java.naming,java.net.http,java.sql,java.xml,jdk.unsupported,jdk.crypto.ec,jdk.zipfs,jdk.management'
    subprocess.run([str(jdk/'bin/jlink'),'--add-modules',modules,'--strip-debug','--no-header-files','--no-man-pages','--compress=2','--output',str(build/'Runtime')],check=True)
if not (build/'Interface.soundbank').exists():
    subprocess.run(['python3',str(root/'tools/make-soundbank.py')],check=True)
voice=root/'Assets/Voice/welcome.mp3'
if not voice.exists():raise SystemExit('The user-provided Clara announcement is required at Assets/Voice/welcome.mp3. See README.md.')
shutil.copy2(voice,build/'welcome.mp3')
subprocess.run(['python3',str(root/'tools/package-app.py')],check=True)
