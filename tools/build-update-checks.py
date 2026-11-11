"""Build the real x86 client test harness without the application entry point."""
from pathlib import Path
import os,subprocess
root=Path(__file__).resolve().parent.parent
sources=sorted(p for p in (root/'Sources').glob('*.swift') if p.name!='LauncherViews.swift')
build=root/'build';build.mkdir(exist_ok=True)
subprocess.run(['swiftc','-swift-version','5','-Onone' if os.environ.get('HARBOR_FAST_QA')=='1' else '-O','-whole-module-optimization','-target','arm64-apple-macos26.0',*map(str,sources),str(root/'tools/UpdateChecks.swift'),str(root/'tools/DiscoveryChecks.swift'),'-o',str(build/'update-checks')],check=True)
