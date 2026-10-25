"""Package the native app with its own headless Java runtime; never copies player data."""
from pathlib import Path
import os, plistlib, shutil, subprocess

root=Path(__file__).resolve().parent.parent
build=root/'build'
app=build/'MC Harbor.app'
contents=app/'Contents';resources=contents/'Resources';macos=contents/'MacOS'
for directory in [resources,macos]:directory.mkdir(parents=True,exist_ok=True)
shutil.copy2(build/'MCHarbor',macos/'MCHarbor')
with (contents/'Info.plist').open('wb') as file:
    plistlib.dump({'CFBundleName':'MC Harbor','CFBundleDisplayName':'MC Harbor','CFBundleExecutable':'MCHarbor','CFBundleIdentifier':'net.morben.shenggan.launcher','CFBundlePackageType':'APPL','CFBundleVersion':'150','CFBundleShortVersionString':'1.5.0','CFBundleIconFile':'HarborMark.icns','LSMinimumSystemVersion':'26.0','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication','NSHumanReadableCopyright':'HMCL © huangyuhui and contributors. Native interface adapted from WinHarbor. GPL-3.0-or-later.'},file)
shutil.copy2(build/'Backend.jar',resources/'Backend.jar')
core=Path(os.environ.get('HMCL_CORE_JAR',str(root/'vendor/HMCLCore.jar' if (root/'vendor/HMCLCore.jar').exists() else Path('/Applications/稳定版我的世界启动器.jar'))))
shutil.copy2(core,resources/'HMCLCore.jar')
for name in ['Loaders','Brand','SkinViewer','Skins','Localization']:
    shutil.copytree(root/'Assets'/name,resources/name,dirs_exist_ok=True)
for name in ['welcome.mp3','welcome-male.mp3','welcome-female2.mp3','welcome-male2.mp3']:
    shutil.copy2(root/'Assets/Voice'/name,resources/name)
shutil.copy2(root/'Assets/Services.json',resources/'Services.json')
if (resources/'welcome.wav').exists():(resources/'welcome.wav').unlink()
shutil.copy2(build/'Interface.soundbank',resources/'Interface.soundbank')
if (resources/'Sounds').exists():shutil.rmtree(resources/'Sounds')
if not (resources/'Runtime').exists():shutil.copytree(build/'Runtime',resources/'Runtime',symlinks=True)
fx=resources/'javafx';fx.mkdir(exist_ok=True)
fxroot=Path(os.environ.get('HMCL_FX_DIR',str(root/'vendor/javafx' if (root/'vendor/javafx').exists() else Path('/Applications/.hmcl/dependencies/macos-arm64/openjfx'))))
for file in fxroot.glob('*21.0.8*.jar'):shutil.copy2(file,fx/file.name)
license_dir=resources/'Licenses';license_dir.mkdir(exist_ok=True)
source=root/'Licenses' if (root/'Licenses').exists() else root.parent/'Harbor'/'upstream'
for file in source.glob('LICENSE*'):shutil.copy2(file,license_dir/file.name)
if not any(license_dir.glob('LICENSE*')):
    for file in (root.parent/'Harbor'/'upstream').glob('LICENSE*'):shutil.copy2(file,license_dir/file.name)
shutil.copy2(root/'Licenses/Terracotta-AGPL-3.0.txt',license_dir/'Terracotta-AGPL-3.0.txt')
shutil.copy2(root/'Licenses/Terracotta-IPC-EXCEPTION.md',license_dir/'Terracotta-IPC-EXCEPTION.md')
(license_dir/'NOTICE.txt').write_text('MC Harbor 1.5.0\nNative macOS UI adapted from the user-provided WinHarbor SwiftUI/AppKit source.\nHMCL stable engine © huangyuhui and contributors, GPL-3.0-or-later. Default loader artwork redrawn with imagegen; original instance and resource icons retained.\nOpenJFX 21.0.8 is distributed under GPLv2 with Classpath Exception; see project source links in the delivery guide.\nBellSoft OpenJDK 21 runtime is distributed under GPLv2 with Classpath Exception; bundled legal notices are in Runtime/legal.\nWelcome announcements: four user-provided ElevenLabs recordings (Clara, Adam, Clara 2, Morgan), retained byte-for-byte and played offline without rate or timbre modification.\nInterface sounds by JDSherbert — https://jdsherbert.itch.io/ultimate-ui-sfx-pack. Used in this finished app as a soundbank under the author license; no standalone redistribution. No Steam sound is sampled.\nMinecraft skin preview: skinview3d 3.4.2 by bs-community (MIT), with Three.js and skinview-utils; license texts retained in SkinViewer.\nOriginal folded h design developed from the user reference and imagegen; production transparent icon rendered from native vector paths. Design history included in corresponding source.\nLocalization metadata: xfl03/I18nUpdateMod3 (AGPL-3.0); license retained in Localization/I18nUpdateMod.LICENSE.\nOptional community language pack: CFPAOrg/Minecraft-Mod-Language-Package (CC BY-NC-SA 4.0), downloaded on demand with MD5 verification; exported translations retain attribution. Full license retained in Localization/CFPA.LICENSE.\nHabier/minecraft-modpack-translator (MIT) informed the extraction workflow; no external GUI or AI service is bundled. Reference license retained in Localization/Habier.LICENSE.\nTerracotta © burningtnt and contributors, AGPL-3.0-or-later with the upstream IPC exception for unmodified executables; downloaded on demand from official releases. Visible UI attribution and upstream source link retained. EasyTier is embedded by Terracotta; no changes to either core.\nOptical interactions draw inspiration from reactdrops.dev; no third-party brand graphics are included.\n')
iconset=build/'AppIcon.iconset'
subprocess.run(['swift',str(root/'tools/make-icon.swift'),str(iconset)],check=True)
for old_icon in resources.glob('*.icns'):old_icon.unlink()
subprocess.run(['/usr/bin/iconutil','-c','icns',str(iconset),'-o',str(resources/'HarborMark.icns')],check=True)
# Sign inner runtime Mach-O files before the enclosing bundle.
runtime=resources/'Runtime'
for file in sorted(runtime.rglob('*')):
    if not file.is_file() or file.is_symlink():continue
    with file.open('rb') as stream:magic=stream.read(4)
    if magic in [b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe']:
        subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(file)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(app)],check=True)
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
print(app)
