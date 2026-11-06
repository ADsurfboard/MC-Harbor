"""Compile production compatibility logic for x86_64 and exercise it on Intel or Rosetta."""
from pathlib import Path
import os, subprocess
root=Path(__file__).resolve().parent.parent
build=root/'build';build.mkdir(exist_ok=True)
skin=(root/'Sources/LittleSkin.swift').read_text()
prefix=skin[:skin.index('struct LittleSkinEntry:')]
assert 'enum HarborHTTP {' in prefix and 'CredentialOriginGuard' in prefix
http=build/'QA-HarborHTTP.swift';http.write_text(prefix)
binary=build/'compatibility-checks'
subprocess.run(['swiftc','-swift-version','5','-target','x86_64-apple-macos12.0',str(root/'Sources/LegacyUI.swift'),str(root/'Sources/LocalTranslation.swift'),str(http),str(root/'tools/CompatibilityChecks.swift'),'-o',str(binary)],check=True)
subprocess.run([str(binary)],check=True,env=os.environ.copy(),timeout=90)
