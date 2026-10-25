"""Verify the actual local delivery, restored ZIP, corresponding source and untouched HMCL core."""
from pathlib import Path
import hashlib,json,plistlib,shutil,subprocess,zipfile

root=Path(__file__).resolve().parent.parent
output=root.parents[1]/'outputs'
version='1.5.0'
archive=output/f'MC-Harbor-{version}-macOS-arm64.zip'
source=output/f'MC-Harbor-{version}-source.zip'
recovery=root/'evidence/package-recovery'
# This directory contains only our previous delivery recovery, never game or account data.
if recovery.exists():shutil.rmtree(recovery)
recovery.mkdir()
with zipfile.ZipFile(archive) as bundle:
    assert bundle.testzip() is None
    assert 'MC-Harbor-Introduction.pdf' in bundle.namelist() and 'README-Install.txt' in bundle.namelist()
    assert bundle.read('MC-Harbor-Introduction.pdf')==(output/'MC-Harbor-启动器介绍.pdf').read_bytes()
subprocess.run(['/usr/bin/ditto','-x','-k',str(archive),str(recovery)],check=True)
apps=[output/'MC Harbor.app',Path('/Applications/MC Harbor.app'),recovery/'MC Harbor.app']
def manifest(app):
    result={}
    for file in sorted(app.rglob('*')):
        if file.is_symlink():result[str(file.relative_to(app))]='symlink:'+str(file.readlink())
        elif file.is_file():result[str(file.relative_to(app))]=hashlib.sha256(file.read_bytes()).hexdigest()
    return result
payloads=[]
for app in apps:
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    assert info['CFBundleShortVersionString']==version
    assert info['CFBundleName']==info['CFBundleDisplayName']=='MC Harbor'
    for path in ['Brand/Icon.png','Brand/Mark.png','SkinViewer/index.html','SkinViewer/skinview3d.bundle.js','SkinViewer/skinview3d.LICENSE','SkinViewer/three.LICENSE','SkinViewer/skinview-utils.LICENSE','Skins/wide/steve.png','welcome.mp3','Localization/i18n-metadata.json','Localization/CFPA.LICENSE','Localization/I18nUpdateMod.LICENSE']:
        assert (app/'Contents/Resources'/path).is_file(),path
    payloads.append(manifest(app))
assert payloads[0]==payloads[1]==payloads[2],'Installed, delivery and ZIP-restored payloads differ'
voice=(root/'Assets/Voice/welcome.mp3').read_bytes()
reference=Path.home()/'Downloads/ElevenLabs_2026-10-24T16_45_11_Clara - Clear, Calm, PA Systems_pvc_sp100_s50_sb95_v4.mp3'
assert hashlib.sha256(voice).hexdigest()=='2470905a5ffe23b4564aa5e5d126fc77aa55d49b82202c42ce3d1a7c870de60b'
if reference.exists():assert voice==reference.read_bytes()
for app in apps:
    resources=app/'Contents/Resources'
    assert (resources/'welcome.mp3').read_bytes()==voice
    for name in ['welcome-male.mp3','welcome-female2.mp3','welcome-male2.mp3']:
        assert (resources/name).read_bytes()==(root/'Assets/Voice'/name).read_bytes()
    assert json.loads((resources/'Services.json').read_text())['friends']=='https://mc-harbor-friends.dinakesidkeiwkkeksos.workers.dev'
    assert not (resources/'welcome.wav').exists()
    assert (resources/'Brand/Icon.png').read_bytes()==(root/'Assets/Brand/Icon.png').read_bytes()
    assert len(list(resources.glob('*.icns')))==1
assert not any('applicationIconImage' in file.read_text() for file in (root/'Sources').glob('*.swift'))
with zipfile.ZipFile(source) as bundle:
    assert bundle.testzip() is None
    names=bundle.namelist()
    assert all(name.startswith('MC-Harbor-source/') for name in names)
    forbidden=['Interface.soundbank','accounts.json','preferences.json','migration.json','user-account-private-data.json']
    assert not any(Path(name).name in forbidden or '/evidence/' in name or '/voice-assets/' in name for name in names)
    assert not any(name.endswith('.wav') for name in names)
    for path in ['Sources/Brand.swift','Sources/ImageCache.swift','Sources/Skins.swift','Sources/AccountCenter.swift','Sources/ResourceServices.swift','Sources/LocalizationWorkspace.swift','Sources/WorldEditor.swift','Sources/FrostedSurface.swift','backend/net/morben/shenggan/NativeLocalization.java','backend/net/morben/shenggan/NativeWorldEditor.java','backend/net/morben/shenggan/NativeModMetadata.java','backend/net/morben/shenggan/NativeDependencies.java','Assets/Brand/Icon.png','Assets/Voice/welcome.mp3','Assets/Localization/i18n-metadata.json','Assets/Localization/CFPA.LICENSE','Assets/SkinViewer/index.html','Assets/SkinViewer/skinview3d.bundle.js','Assets/SkinViewer/three.LICENSE','docs/ICON_PROMPT.md','Sources/Chat.swift','Sources/Friends.swift','Sources/Terracotta.swift','Sources/WallpaperLibrary.swift','Sources/LittleSkin.swift','Assets/Services.json','Assets/Voice/welcome-male.mp3','Assets/Voice/welcome-female2.mp3','Assets/Voice/welcome-male2.mp3','social-cloud/worker.mjs','social-cloud/schema.sql','social-cloud/wrangler.jsonc','social-server/server.py','BUILDING.md','docs/SERVICES.md','MC-Harbor-Introduction.pdf','vendor/HMCLCore.jar','upstream/HMCL-3.16.4-source.tar.gz']:
        assert 'MC-Harbor-source/'+path in names,path
core=Path('/Applications/稳定版我的世界启动器.jar')
digest=hashlib.sha256(core.read_bytes()).hexdigest()
assert digest=='98f0123f38e86a606aa583f74d21ae74128679e921ea7ec0c43ab26303767e9e'
report={'version':version,'strictSignatureAllThree':True,'appZIPCRC':True,'sourceZIPCRC':True,'restoredPayloadMatchesInstalled':True,'payloadFiles':len(payloads[0]),'sourcePrivateDataExcluded':True,'restrictedAudioExcludedFromSource':True,'ClaraOriginalMP3AllThree':True,'originalReferenceAvailable':reference.exists(),'allFourOriginalVoices':True,'PDFIncluded':True,'builtInFriendsEndpoint':True,'oldAnnouncementAbsent':True,'singleBundledIconWithoutRuntimeOverride':True,'originalHMCLUnchanged':True,'originalHMCLSHA256':digest,'appZIPBytes':archive.stat().st_size,'sourceZIPBytes':source.stat().st_size,'appZIPSHA256':hashlib.sha256(archive.read_bytes()).hexdigest(),'sourceZIPSHA256':hashlib.sha256(source.read_bytes()).hexdigest()}
(root/'evidence/delivery-report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
