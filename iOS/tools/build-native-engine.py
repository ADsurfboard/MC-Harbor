#!/usr/bin/env python3
"""Build the pinned real iOS JVM/graphics engine with Harbor's native SwiftUI UI.

All patches apply to a marked, reproducible build copy. Neither the submodule nor
the macOS source, installed app, player data or credentials are modified.
"""
from pathlib import Path
import argparse, subprocess, shutil, json, plistlib, os, hashlib, sys

IOS=Path(__file__).resolve().parents[1]; REPO=IOS.parent
UPSTREAM='f98c4133c72d39e06ceac42b57cc4477c52105fc'
parser=argparse.ArgumentParser()
parser.add_argument('--platform',choices=['device','simulator'],default='simulator')
parser.add_argument('--prepare-only',action='store_true')
args=parser.parse_args()
SOURCE=REPO/'vendor/AmethystIOS'
BUILD=IOS/'.build'/('engine-'+args.platform)
ENGINE=BUILD/'source'
EVIDENCE=IOS/'evidence'; EVIDENCE.mkdir(exist_ok=True)
sdk='iphoneos' if args.platform=='device' else 'iphonesimulator'
def run(command,cwd=REPO,**kwargs):
    print('+',' '.join(map(str,command)),flush=True)
    return subprocess.run(list(map(str,command)),cwd=cwd,check=True,**kwargs)
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=SOURCE,text=True).strip()==UPSTREAM
assert not subprocess.check_output(['git','diff','--name-only'],cwd=SOURCE),'Upstream checkout has local changes'
if ENGINE.exists():
    marker=ENGINE/'.harbor-build-copy.json'
    assert marker.is_file() and json.loads(marker.read_text())['upstream']==UPSTREAM,'Refusing to replace an unmarked directory'
    shutil.rmtree(ENGINE)
ENGINE.parent.mkdir(parents=True,exist_ok=True)
shutil.copytree(SOURCE,ENGINE,symlinks=True,ignore=shutil.ignore_patterns('.git','build','artifacts','depends'))
(ENGINE/'.harbor-build-copy.json').write_text(json.dumps({'upstream':UPSTREAM,'purpose':'rebuildable iOS engine copy'}))
patches=[]
def replace(relative,old,new,count=1):
    p=ENGINE/relative;s=p.read_text();assert s.count(old)==count,(relative,s.count(old),old[:80])
    p.write_text(s.replace(old,new));patches.append({'file':relative,'replacements':count})

for name in ['HarborEngineAdapter.h','HarborEngineAdapter.m','HarborArchiveGuard.h','HarborArchiveGuard.m']:
    shutil.copy2(IOS/'Native'/name,ENGINE/'Natives'/name)
replace('Natives/ios_uikit_bridge.m','#import "SurfaceViewController.h"','#import "SurfaceViewController.h"\n#import "HarborEngineAdapter.h"')
replace('Natives/ios_uikit_bridge.m','void launchInitialViewController(UIWindow *window) {\n    window.rootViewController = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];','void launchInitialViewController(UIWindow *window) {\n    HBRInstallRoot(window);')
replace('Natives/ios_uikit_bridge.m','window.rootViewController = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];','HBRInstallRoot(window);',count=2)
replace('Natives/SurfaceViewController.m','#import "SurfaceViewController.h"','#import "SurfaceViewController.h"\n#import "HarborEngineAdapter.h"')
replace('Natives/SurfaceViewController.m','[super viewDidAppear:animated];','[super viewDidAppear:animated];\n    HBRInstallGameControls(self);')
replace('Natives/SurfaceViewController.m','- (void)updateGrabState {','- (void)updateGrabState {\n    HBRUpdateGameGrabState();')
replace('Natives/SurfaceViewController.m','    CGFloat screenScale = self.screenScale;','    if (event == ACTION_MOVE_MOTION && isGrabbing) location = HBRApplyLookDelta(location);\n    CGFloat screenScale = self.screenScale;')

# Validate complete manifests before any downloaded / extracted payload is written.
replace('Natives/installer/modpack/ModrinthAPI.m','#import "PLProfiles.h"','#import "PLProfiles.h"\n#import "HarborArchiveGuard.h"')
replace('Natives/installer/modpack/ModrinthAPI.m','    NSData *indexData = [archive extractDataFromFile:',
    '    if (!HBRValidateArchive(archive, destPath, &error)) { [downloader finishDownloadWithErrorString:error.localizedDescription]; return; }\n    NSData *indexData = [archive extractDataFromFile:')
replace('Natives/installer/modpack/ModrinthAPI.m','    downloader.progress.totalUnitCount = [indexDict[@"files"] count];',
    '    if (!HBRValidateRemoteFiles(indexDict[@"files"], destPath, &error)) { [downloader finishDownloadWithErrorString:error.localizedDescription]; return; }\n    downloader.progress.totalUnitCount = [indexDict[@"files"] count];')
utils=ENGINE/'Natives/installer/modpack/ModpackUtils.m';content=utils.read_text()
a=content.index('+ (void)archive:');b=content.index('\n+ (NSDictionary *)infoForDependencies:',a)
content=content[:a]+''' + (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError *__autoreleasing*)error {
    HBRExtractDirectory(archive, dir, path, error);
}
'''+content[b:]
utils.write_text('#import "HarborArchiveGuard.h"\n'+content)

# Tokens and accounts remain outside the Files-sharing Documents directory.
main=(ENGINE/'Natives/main.m').read_text();start=main.index('void init_setupHomeDirectory() {');end=main.index('\nint main(',start)
main=main[:start]+'''void init_setupHomeDirectory() {
    NSError *error = nil;
    NSURL *support = [fm URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
    NSURL *home = [support URLByAppendingPathComponent:@"MC-Harbor" isDirectory:YES];
    BOOL success = home && [fm createDirectoryAtURL:home withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error];
    if (!success) { NSLog(@"MC Harbor private storage could not be created: %@", error.localizedDescription); exit(1); }
    setenv("AME_HOME", home.path.fileSystemRepresentation, 1);
}
''' + main[end:]
(ENGINE/'Natives/main.m').write_text(main);patches.append({'file':'Natives/main.m','privatePersistentStorage':True})

cmake=ENGINE/'Natives/CMakeLists.txt';s=cmake.read_text()
target='arm64-apple-ios16.0' + ('-simulator' if args.platform=='simulator' else '')
s=s.replace('-target arm64-apple-ios -mcpu=apple-a8','-target '+target)
s+='''\n# MC Harbor native UI and real input adapter\ntarget_sources(AngelAuraAmethyst PRIVATE HarborEngineAdapter.m HarborArchiveGuard.m)\ntarget_link_libraries(AngelAuraAmethyst PUBLIC "-framework HarborIOSUI" "-framework HarborCore")\n'''
cmake.write_text(s)
make=ENGINE/'Makefile';s=make.read_text().replace('-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0','-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0')
s=s.replace('-DCMAKE_C_FLAGS="-arch arm64"', '-DCMAKE_C_FLAGS="-arch arm64 -target '+target+'"')
s=s.replace('&& cmake \\\n','&& cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \\\n')
# Retain the upstream runtime's license / notices in every distributable.
s=s.replace('ASSEMBLY_EXCEPTION,bin,include,jre,legal,LICENSE,man,THIRD_PARTY_README,','bin,include,jre,man,')
if args.platform=='simulator':s=s.replace('--platform iphoneos','--platform iphonesimulator')
make.write_text(s)

info=ENGINE/'Natives/Info.plist';p=plistlib.loads(info.read_bytes())
p.update(CFBundleIdentifier='net.morben.harbor.ios',CFBundleDisplayName='MC Harbor',CFBundleName='MC Harbor',CFBundleShortVersionString='0.1.0',CFBundleVersion='1',MinimumOSVersion='16.0')
p['CFBundleURLTypes']=[{'CFBundleURLName':'net.morben.harbor.ios.launch','CFBundleURLSchemes':['mcharbor','amethyst']}]
info.write_bytes(plistlib.dumps(p))
(BUILD/'patch-proof.json').write_text(json.dumps({'upstream':UPSTREAM,'platform':args.platform,'patches':patches,'privateStorage':True,'runtimeLicensesRetained':True},indent=2))
if args.prepare_only:
    print('Prepared pinned native engine:',ENGINE,flush=True);sys.exit(0)

run(['xcodegen','generate'],cwd=IOS)
derived=IOS/'build'/('ui-'+args.platform)
run(['xcodebuild','-project','MCHarborIOS.xcodeproj','-scheme','HarborIOSUI','-sdk',sdk,'-destination','generic/platform='+('iOS' if args.platform=='device' else 'iOS Simulator'),'-derivedDataPath',derived,'CODE_SIGNING_ALLOWED=NO','build'],cwd=IOS)
frameworks=ENGINE/'Natives/resources/Frameworks'
for name in ['HarborCore','HarborIOSUI']:
    product=derived/'Build/Products'/('Debug-iphoneos' if args.platform=='device' else 'Debug-iphonesimulator')/(name+'.framework')
    assert product.is_dir(),product
    shutil.copytree(product,frameworks/product.name,symlinks=True,dirs_exist_ok=True)
# The pinned upstream carries iOS-arm64 graphics binaries. Its own simulator
# recipe changes the platform only after linking, which is too late for ld.
# Keep the conversion confined to the generated source copy, before link time.
def macho_files(root):
    magic={b'\xfe\xed\xfa\xce',b'\xce\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'}
    for file in root.rglob('*'):
        if file.is_symlink() or not file.is_file():continue
        with file.open('rb') as stream:header=stream.read(4)
        if header in magic:yield file
if args.platform=='simulator':
    for binary in list(macho_files(frameworks))+list(macho_files(ENGINE/'Natives/external/MobileGlues/src/main/cpp/libraries/ios')):
        run(['xcrun','vtool','-arch','arm64','-set-build-version','7','16.0','26.0','-replace','-output',binary,binary])
sdkpath=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()
java_home=os.environ.get('JAVA_HOME_8_X64') or os.environ.get('JAVA_HOME')
if not java_home:java_home=subprocess.check_output(['/usr/libexec/java_home','-v','1.8'],text=True).strip()
java_bin=Path(java_home)/'bin'
run(['make','-j2','payload','SDKPATH='+sdkpath,'BOOTJDK='+str(java_bin),'PLATFORM='+('2' if args.platform=='device' else '7'),'RELEASE=0','JOBS=2','RUNNER=0'],cwd=ENGINE)
produced=ENGINE/'artifacts/Payload/AngelAuraAmethyst.app';assert produced.is_dir()
destination=IOS/'build'/('MC-Harbor-'+args.platform+'.app')
if destination.exists():shutil.rmtree(destination)
shutil.copytree(produced,destination,symlinks=True)
notices=destination/'Licenses';notices.mkdir(exist_ok=True)
shutil.copy2(SOURCE/'LICENSE',notices/'Amethyst-GPL.txt');shutil.copy2(REPO/'LICENSE',notices/'MC-Harbor-GPL.txt')
for binary in macho_files(destination):
    run(['codesign','--force','--sign','-',binary])
for framework in sorted((destination/'Frameworks').glob('*.framework')):
    run(['codesign','--force','--sign','-',framework])
run(['codesign','--force','--sign','-',destination])
run(['codesign','--verify','--deep','--strict',destination])
report={'upstream':UPSTREAM,'platform':args.platform,'app':str(destination),'nativeExecutable':(destination/'AngelAuraAmethyst').is_file(),'frameworks':[x.name for x in (destination/'Frameworks').glob('Harbor*.framework')],'javaRuntimes':[x.name for x in (destination/'java_runtimes').iterdir() if x.is_dir()]}
(EVIDENCE/('native-build-'+args.platform+'.json')).write_text(json.dumps(report,indent=2))
print(json.dumps(report),flush=True)
