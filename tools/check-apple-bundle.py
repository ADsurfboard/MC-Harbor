from pathlib import Path
import hashlib,os,plistlib,subprocess,zipfile
r=Path(__file__).resolve().parent.parent;a=r/'build/MC Harbor.app';res=a/'Contents/Resources';info=plistlib.loads((a/'Contents/Info.plist').read_bytes())
assert info['CFBundleShortVersionString']=='1.6.2' and info['LSMinimumSystemVersion']=='26.0'
for p in [a/'Contents/MacOS/MCHarbor',res/'Runtime/bin/java',res/'InstanceShortcut']:
 assert subprocess.check_output(['lipo','-archs',str(p)],text=True).strip()=='arm64'
subprocess.run(['codesign','--verify','--deep','--strict',str(a)],check=True)
for name in ['welcome.mp3','welcome-male.mp3','welcome-female2.mp3','welcome-male2.mp3']:
 assert (res/name).read_bytes()==(r/'Assets/Voice'/name).read_bytes()
for name in ['flowerbank.png','jiekee.png','shiziyueyuan.png','contributors.json']:assert (res/'Contributors'/name).read_bytes()==(r/'Assets/Contributors'/name).read_bytes()
assert len(list((res/'javafx').glob('*mac-aarch64.jar')))==3
assert 'glassEffect(' in (r/'Sources/HarborTheme.swift').read_text()
assert 'OpticalRim' not in '\n'.join(p.read_text() for p in (r/'Sources').glob('*.swift'))
if os.environ.get('HARBOR_TEST_WITHOUT_SFX')!='1':assert (res/'Interface.soundbank').stat().st_size>0
print('PASS Apple arm64 app/runtime/shortcut, native glass, voices, artwork and strict signature')
