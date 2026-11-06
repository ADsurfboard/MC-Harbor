"""Build the Intel compatibility edition, targeting macOS 12 and later."""
from pathlib import Path
import os, subprocess

root=Path(__file__).resolve().parent.parent
build=root/'build';build.mkdir(exist_ok=True)
deps=build/'intel-deps'
homes=list((deps/'jre-extract').glob('*/Contents/Home'))
runtime=Path(os.environ['HARBOR_RUNTIME_HOME']) if os.environ.get('HARBOR_RUNTIME_HOME') else (homes[0] if len(homes)==1 else None)
fx=Path(os.environ.get('HMCL_FX_DIR',str(deps)))
if runtime is None or not (runtime/'bin/java').is_file():raise SystemExit('Run python3 tools/setup-intel-deps.py first, or set HARBOR_RUNTIME_HOME to an Intel Java 21 runtime.')
arch=subprocess.check_output(['/usr/bin/lipo','-archs',str(runtime/'bin/java')],text=True).split()
if 'x86_64' not in arch:raise SystemExit('The bundled Java runtime must support Intel x86_64.')
if len(list(fx.glob('javafx-*-21.0.8-mac.jar')))!=3:raise SystemExit('Run tools/setup-intel-deps.py to obtain the three Intel OpenJFX JARs.')
bank=build/'Interface.soundbank'
if not bank.is_file() and os.environ.get('HARBOR_TEST_WITHOUT_SFX')!='1':
    if os.environ.get('JDS_WAV_DIR'):subprocess.run(['python3',str(root/'tools/make-soundbank.py')],check=True)
    else:raise SystemExit('The licensed soundbank is required for a release; set JDS_WAV_DIR as described in BUILDING.md.')
environment=dict(os.environ,HMCL_FX_DIR=str(fx),HARBOR_RUNTIME_HOME=str(runtime))
subprocess.run(['swiftc','-swift-version','5','-O','-whole-module-optimization','-target','x86_64-apple-macos12.0',*[str(p) for p in sorted((root/'Sources').glob('*.swift'))],'-o',str(build/'MCHarbor')],check=True)
subprocess.run(['python3',str(root/'tools/build-backend.py')],check=True,env=environment)
subprocess.run(['python3',str(root/'tools/package-app.py')],check=True,env=environment)
