"""Inspect the complete signed Intel bundle, including its embedded JVM and JavaFX libraries."""
from pathlib import Path
import json,os,plistlib,struct,subprocess,zipfile

root=Path(__file__).resolve().parent.parent
app=root/'build/MC Harbor.app';resources=app/'Contents/Resources'
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['LSMinimumSystemVersion']=='12.0' and info['CFBundleShortVersionString']=='1.5.2'
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)

def inspect(data,label):
    if data[:4]!=b'\xcf\xfa\xed\xfe':return False
    assert len(data)>=32,label
    _,cpu,_,_,count,_,_,_=struct.unpack_from('<8I',data)
    assert cpu==0x01000007,('Non-Intel Mach-O',label,hex(cpu))
    position=32;minimum=None
    for _ in range(count):
        cmd,size=struct.unpack_from('<II',data,position)
        assert size>=8 and position+size<=len(data),label
        if cmd==0x32:
            platform,version=struct.unpack_from('<II',data,position+8)
            assert platform==1,('Not macOS',label)
            minimum=version
        elif cmd==0x24:minimum=struct.unpack_from('<I',data,position+8)[0]
        position+=size
    assert minimum is not None and minimum <= (12<<16),('Minimum macOS too new',label,minimum)
    return True

binary=app/'Contents/MacOS/MCHarbor'
assert inspect(binary.read_bytes(),'launcher')
native=0
for file in (resources/'Runtime').rglob('*'):
    if file.is_symlink() or not file.is_file():continue
    with file.open('rb') as stream:
        if stream.read(4)!=b'\xcf\xfa\xed\xfe':continue
    data=file.read_bytes()
    if inspect(data,str(file.relative_to(resources))):native+=1
assert native>=20,('Missing Intel runtime files',native)
libraries=0
fx=sorted((resources/'javafx').glob('javafx-*-21.0.8-mac.jar'));assert len(fx)==3
for jar in fx:
    with zipfile.ZipFile(jar) as archive:
        assert archive.testzip() is None
        for name in archive.namelist():
            if name.endswith('.dylib'):
                assert inspect(archive.read(name),jar.name+':'+name);libraries+=1
assert libraries>=5
assert subprocess.run([str(resources/'Runtime/bin/java'),'-version'],capture_output=True,text=True,timeout=30).returncode==0
for name in ['welcome.mp3','welcome-male.mp3','welcome-female2.mp3','welcome-male2.mp3']:
    assert (resources/name).read_bytes()==(root/'Assets/Voice'/name).read_bytes()
bank=resources/'Interface.soundbank'
if os.environ.get('HARBOR_TEST_WITHOUT_SFX')!='1':assert bank.is_file() and bank.read_bytes()==(root/'build/Interface.soundbank').read_bytes()
assert (resources/'Contributors/jiekee.png').read_bytes()==(root/'Assets/Contributors/jiekee.png').read_bytes()
assert len(list(resources.glob('*.icns')))==1
assert 'glassEffect(' not in '\n'.join(p.read_text() for p in (root/'Sources').glob('*.swift'))
report={'minimumMacOS':'12.0','launcherArchitecture':'x86_64','runtimeMachOFiles':native,'javafxNativeLibraries':libraries,'strictSignature':True,'voicesByteIdentical':True,'licensedSoundbankIncluded':bank.is_file(),'liquidGlassRemoved':True}
evidence=root/'evidence';evidence.mkdir(exist_ok=True)
(evidence/'intel-bundle-report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
