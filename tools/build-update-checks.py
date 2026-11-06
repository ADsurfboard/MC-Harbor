"""Build the real x86 client test harness without the application entry point."""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parent.parent
sources=sorted(p for p in (root/'Sources').glob('*.swift') if p.name!='LauncherViews.swift')
build=root/'build';build.mkdir(exist_ok=True)
subprocess.run(['swiftc','-swift-version','5','-O','-whole-module-optimization','-target','x86_64-apple-macos15.0',*map(str,sources),str(root/'tools/UpdateChecks.swift'),'-o',str(build/'update-checks')],check=True)
