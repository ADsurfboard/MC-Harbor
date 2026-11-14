#!/usr/bin/env python3
"""Build the pinned real iOS JVM/graphics engine with Harbor's native SwiftUI UI.

All patches apply to a marked, reproducible build copy. Neither the submodule nor
the macOS source, installed app, player data or credentials are modified.
"""
from pathlib import Path
import argparse, subprocess, shutil, json, plistlib, os, hashlib, sys, re, tempfile, zipfile, stat

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

# javac resolves dependent sources implicitly. The upstream per-file rules share
# build/classes, so parallel javac processes can truncate each other's output.
# Serialize this Java sub-make only; native C/C++ compilation remains bounded
# and parallel. Keep the empty-class gate and order it after all class writes.
replace('JavaApp/Makefile', '# Prerequisite variables',
        '.NOTPARALLEL:\n\n# Prerequisite variables')
replace('JavaApp/Makefile', 'check_empty_classes:',
        'check_empty_classes: $(CLASSES)')

for name in ['HarborEngineAdapter.h','HarborEngineAdapter.m','HarborArchiveGuard.h','HarborArchiveGuard.m','HarborAccountTokenStore.h','HarborAccountTokenStore.m','HarborModpackMetadata.h','HarborModpackMetadata.m']:
    shutil.copy2(IOS/'Native'/name,ENGINE/'Natives'/name)
replace('Natives/ios_uikit_bridge.m','#import "SurfaceViewController.h"','#import "SurfaceViewController.h"\n#import "HarborEngineAdapter.h"')
replace('Natives/ios_uikit_bridge.m','void launchInitialViewController(UIWindow *window) {\n    window.rootViewController = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];','void launchInitialViewController(UIWindow *window) {\n    HBRInstallRoot(window);')
replace('Natives/ios_uikit_bridge.m','window.rootViewController = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];','HBRInstallRoot(window);',count=2)
replace('Natives/SurfaceViewController.m','#import "SurfaceViewController.h"','#import "SurfaceViewController.h"\n#import "HarborEngineAdapter.h"')
replace('Natives/SurfaceViewController.m','[super viewDidAppear:animated];','[super viewDidAppear:animated];\n    HBRInstallGameControls(self);')
replace('Natives/SurfaceViewController.m','- (void)updateGrabState {','- (void)updateGrabState {\n    HBRUpdateGameGrabState();')
replace('Natives/SurfaceViewController.m','    CGFloat screenScale = self.screenScale;','    if (event == ACTION_MOVE_MOTION && isGrabbing) location = HBRApplyLookDelta(location);\n    CGFloat screenScale = self.screenScale;')
replace('Natives/installer/ForgeInstallViewController.m', '#import "AFNetworking.h"',
        '#import "AFNetworking.h"\n#import "HarborEngineAdapter.h"')
replace('Natives/installer/ForgeInstallViewController.m',
        'LauncherNavigationController *navVC = (id)((UISplitViewController *)self.presentingViewController).viewControllers[1];',
        'LauncherNavigationController *navVC = (id)HBRLauncherController();\n            if (!navVC) { showDialog(@"无法打开安装器", @"运行层尚未准备好，请返回游戏库后重试。"); return; }')

# A profile editor can now be presented by SwiftUI, not only the old split view.
# Refresh the legacy list only when it is actually the presenting controller.
replace('Natives/LauncherProfileEditorViewController.m', '''    // Call LauncherProfilesViewController's viewWillAppear
    UINavigationController *navVC = (id) ((UISplitViewController *)self.presentingViewController).viewControllers[1];
    [navVC.viewControllers[0] viewWillAppear:NO];''', '''    UIViewController *presenter = self.presentingViewController;
    if ([presenter isKindOfClass:UISplitViewController.class]) {
        UIViewController *detail = ((UISplitViewController *)presenter).viewControllers.lastObject;
        if ([detail isKindOfClass:UINavigationController.class]) {
            [((UINavigationController *)detail).viewControllers.firstObject viewWillAppear:NO];
        }
    }''')
replace('Natives/LauncherProfileEditorViewController.m',
        '    javaList[0] = @"(default)";',
        '    if (!javaList) javaList = [NSMutableArray array];\n    if (javaList.count) javaList[0] = @"(default)";\n    else [javaList addObject:@"(default)"];')
replace('Natives/LauncherProfileEditorViewController.m',
        'NSMutableArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil].mutableCopy;',
        'NSMutableArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil].mutableCopy ?: [NSMutableArray array];')
replace('Natives/LauncherProfileEditorViewController.m',
        '    self.navigationController.modalInPresentation = YES;',
        '    self.navigationItem.leftBarButtonItem.accessibilityIdentifier = @"native.profile.save";\n    self.navigationItem.rightBarButtonItem.accessibilityIdentifier = @"native.profile.cancel";\n    self.navigationController.modalInPresentation = YES;')
replace('Natives/LauncherProfileEditorViewController.m', '''    // We might be saving without ending editing, so make sure textFieldDidEndEditing is always called
    UITextField *currentTextField = [self performSelector:@selector(_firstResponder)];
    if ([currentTextField isKindOfClass:UITextField.class] && [currentTextField isDescendantOfView:self.tableView]) {
        [self textFieldDidEndEditing:currentTextField];
    }''', '''    // Commit the active public text input before serializing the profile.
    [self.view endEditing:YES];''')
replace('Natives/LauncherMenuViewController.m',
        '[self.accountButton setAttributedTitle:(NSAttributedString *)@"" forState:UIControlStateNormal];',
        '[self.accountButton setAttributedTitle:[[NSAttributedString alloc] initWithString:@""] forState:UIControlStateNormal];', count=2)

# Preserve the existing Keychain namespace, secure decoding and all JIT / account
# checks. A failed update must not delete a player's previous working tokens.
auth=ENGINE/'Natives/authenticator/MicrosoftAuthenticator.m';content=auth.read_text()
content='#import "../HarborAccountTokenStore.h"\n'+content
a=content.index('+ (NSDictionary *)tokenDataOfProfile:');b=content.index('\n- (NSDictionary *)tokenData {',a)
content=content[:a]+''' + (NSDictionary *)tokenDataOfProfile:(NSString *)profile {
    return HBRReadAccountTokens(profile);
}

+ (void)clearTokenDataOfProfile:(NSString *)profile {
    HBRClearAccountTokens(profile);
}

- (BOOL)setAccessToken:(NSString *)accessToken refreshToken:(NSString *)refreshToken {
    return HBRStoreAccountTokens(self.authData[@"xuid"], accessToken, refreshToken);
}
'''+content[b:]
old='''        showDialog(localize(@"Error", nil), @"Failed to load account tokens from keychain");
        callback(nil, YES);'''
assert content.count(old)==1
content=content.replace(old,'''        showDialog(localize(@"Error", nil), @"无法读取账号凭证，请重新登录。");
        callback(nil, NO);''')
content=content.replace('    // Move tokens to keychain if we haven\'t\n    if (!self.tokenData) {',
                        '    NSDictionary *tokens = self.tokenData;\n    if (!tokens) {')
content=content.replace('[self acquireAccessToken:self.tokenData[@"refreshToken"] refresh:YES callback:callback];',
                        '[self acquireAccessToken:tokens[@"refreshToken"] refresh:YES callback:callback];')
auth.write_text(content);patches.append({'file':'Natives/authenticator/MicrosoftAuthenticator.m','nonDestructiveKeychainUpdates':True})

# Validate complete manifests before any downloaded / extracted payload is written.
replace('Natives/installer/modpack/ModrinthAPI.m','#import "PLProfiles.h"','#import "PLProfiles.h"\n#import "HarborArchiveGuard.h"\n#import "HarborModpackMetadata.h"')
replace('Natives/installer/modpack/ModrinthAPI.m','    NSData *indexData = [archive extractDataFromFile:',
    '    if (!HBRValidateArchive(archive, destPath, &error)) { [downloader finishDownloadWithErrorString:error.localizedDescription]; return; }\n    NSData *indexData = [archive extractDataFromFile:')
replace('Natives/installer/modpack/ModrinthAPI.m',
        '    NSDictionary* indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];',
        '    NSDictionary* indexDict = HBRParseModpackIndex(indexData, &error);')
replace('Natives/installer/modpack/ModrinthAPI.m','    if (error) {\n        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];',
    '    if (error || ![indexDict isKindOfClass:NSDictionary.class]) {\n        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Invalid modrinth.index.json: %@", error.localizedDescription ?: @"Expected an object"]];')
replace('Natives/installer/modpack/ModrinthAPI.m','    downloader.progress.totalUnitCount = [indexDict[@"files"] count];',
    '''    NSString *versions = [@(getenv("GAME_DIR")) stringByAppendingPathComponent:@"versions"];
    if (!HBRValidateModpackName(indexDict[@"name"], &error) || !HBRResolveModpackDependencies(indexDict[@"dependencies"], versions, &error) ||
        !HBRValidateRemoteFiles(indexDict[@"files"], destPath, &error)) {
        [downloader finishDownloadWithErrorString:error.localizedDescription]; return;
    }
    downloader.progress.totalUnitCount = [indexDict[@"files"] count];''')
replace('Natives/installer/modpack/ModrinthAPI.m', '    for (NSDictionary *indexFile in indexDict[@"files"]) {',
        '    for (NSDictionary *indexFile in indexDict[@"files"]) {\n        if (!HBRModpackFileSupportsClient(indexFile)) { downloader.progress.completedUnitCount++; continue; }')
# Every import has independent storage, regardless of project-supplied titles.
replace('Natives/MinecraftResourceDownloadTask.m','#import "MinecraftResourceDownloadTask.h"',
        '#import "MinecraftResourceDownloadTask.h"\n#import "HarborModpackMetadata.h"')
replace('Natives/MinecraftResourceDownloadTask.m', '''    NSString *name = [[modDetail[@"title"] lowercaseString] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    name = [name stringByReplacingOccurrencesOfString:@" " withString:@"_"];''',
        '    NSString *name = HBRNewModpackStorageName();')
replace('Natives/installer/modpack/ModrinthAPI.m', '        NSString *sha = indexFile[@"hashes"][@"sha1"];',
        '        NSString *sha = [@"sha512:" stringByAppendingString:indexFile[@"hashes"][@"sha512"]];')
replace('Natives/MinecraftResourceDownloadTask.m', '    if (getPrefBool(@"general.check_sha")) {',
        '    if (([sha isKindOfClass:NSString.class] && [sha hasPrefix:@"sha512:"]) || getPrefBool(@"general.check_sha")) {')
download=ENGINE/'Natives/MinecraftResourceDownloadTask.m';content=download.read_text()
a=content.index('- (BOOL)checkSHAIgnorePref:');b=content.index('\n- (BOOL)checkSHA:',a)
content=content[:a]+'''- (BOOL)checkSHAIgnorePref:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (sha && ![sha isKindOfClass:NSString.class]) return NO;
    if (!sha.length) return [NSFileManager.defaultManager fileExistsAtPath:path];
    BOOL strong=[sha hasPrefix:@"sha512:"];
    NSString *expected=strong ? [sha substringFromIndex:7] : sha;
    NSString *actual=HBRFileDigest(path, strong, nil);
    BOOL valid=actual && [actual isEqualToString:expected.lowercaseString];
    if (!valid || (getPrefBool(@"general.debug_logging") && logSuccess)) {
        NSLog(@"[MCDL] %@ %@ for %@", strong ? @"SHA512":@"SHA1", valid ? @"passed":@"failed", altName ?: path.lastPathComponent);
    }
    return valid;
}
'''+content[b:]
download.write_text(content)
modrinth=ENGINE/'Natives/installer/modpack/ModrinthAPI.m';content=modrinth.read_text()
a=content.index('    // Create profile\n');b=content.index('\n}\n\n@end',a)
content=content[:a]+'''    // Preserve existing profiles and worlds when a project/version is imported again.
    if (![depInfo[@"id"] isKindOfClass:NSString.class] || ![depInfo[@"id"] length]) {
        [downloader finishDownloadWithErrorString:@"加载器状态已变化，请重新检查后导入。"]; return;
    }
    NSString *profileName = HBRUniqueModpackName(indexDict[@"name"], PLProfiles.current.profiles);
    NSMutableDictionary *profile = @{
        @"gameDir":[NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name":profileName, @"lastVersionId":depInfo[@"id"]
    }.mutableCopy;
    NSString *iconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:iconPath error:nil];
    if (attributes && [attributes[NSFileSize] unsignedLongLongValue] <= 512*1024) {
        NSData *icon = [NSData dataWithContentsOfFile:iconPath];
        if (icon.length) profile[@"icon"] = [@"data:image/png;base64," stringByAppendingString:[icon base64EncodedStringWithOptions:0]];
    }
    PLProfiles.current.profiles[profileName] = profile;
    PLProfiles.current.selectedProfileName = profileName;'''+content[b:]
modrinth.write_text(content)
utils=ENGINE/'Natives/installer/modpack/ModpackUtils.m';content=utils.read_text()
a=content.index('+ (void)archive:');b=content.index('\n+ (NSDictionary *)infoForDependencies:',a)
content=content[:a]+''' + (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError *__autoreleasing*)error {
    HBRExtractDirectory(archive, dir, path, error);
}
'''+content[b:]
a=content.index('+ (NSDictionary *)infoForDependencies:');b=content.index('\n@end',a)
content=content[:a]+''' + (NSDictionary *)infoForDependencies:(NSDictionary *)dependency {
    NSString *versions = [@(getenv("GAME_DIR")) stringByAppendingPathComponent:@"versions"];
    NSMutableDictionary *info = [HBRResolveModpackDependencies(dependency, versions, nil) mutableCopy];
    if (!info) return @{};
    NSString *minecraftVersion = dependency[@"minecraft"];
    if (dependency[@"fabric-loader"]) {
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"], minecraftVersion, dependency[@"fabric-loader"]];
    } else if (dependency[@"quilt-loader"]) {
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"], minecraftVersion, dependency[@"quilt-loader"]];
    }
    return info;
}
'''+content[b:]
utils.write_text('#import "HarborArchiveGuard.h"\n#import "HarborModpackMetadata.h"\n'+content)

# Fix an upstream use-after-release / duplicate SecTask allocation before use
# on actual devices. Keep entitlement checks intact rather than skipping them.
utils_source=ENGINE/'Natives/utils.m';content=utils_source.read_text()
a=content.index('BOOL getEntitlementValue(NSString *key) {');b=content.index('\nBOOL isJITEnabled(',a)
content=content[:a]+'''BOOL getEntitlementValue(NSString *key) {
    void *task = SecTaskCreateFromSelf(NULL);
    if (!task) return NO;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, key, nil);
    CFRelease(task);
    if (!value) return NO;
    BOOL enabled = ![(__bridge id)value isKindOfClass:NSNumber.class] || [(__bridge id)value boolValue];
    CFRelease(value);
    return enabled;
}
'''+content[b:]
utils_source.write_text(content)

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
s+='''\n# MC Harbor native UI and real input adapter\ntarget_sources(AngelAuraAmethyst PRIVATE HarborEngineAdapter.m HarborArchiveGuard.m HarborAccountTokenStore.m HarborModpackMetadata.m)\ntarget_compile_options(AngelAuraAmethyst PRIVATE "-F${CMAKE_CURRENT_LIST_DIR}/resources/Frameworks")\ntarget_link_libraries(AngelAuraAmethyst PUBLIC "-framework HarborIOSUI" "-framework HarborCore" "-framework Security")\n'''
cmake.write_text(s)
make=ENGINE/'Makefile';s=make.read_text().replace('-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0','-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0')
s=s.replace('-DCMAKE_C_FLAGS="-arch arm64"', '-DCMAKE_C_FLAGS="-arch arm64 -target '+target+'"')
s=s.replace('&& cmake \\\n','&& cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \\\n')
# Retain the upstream runtime's license / notices in every distributable.
s=s.replace('ASSEMBLY_EXCEPTION,bin,include,jre,legal,LICENSE,man,THIRD_PARTY_README,','bin,include,jre,man,')
if args.platform=='simulator':s=s.replace('--platform iphoneos','--platform iphonesimulator')
s=s.replace('curl -OJfSL', 'curl --connect-timeout 15 --max-time 600 --retry 2 -OJfSL')
make.write_text(s)

# Reuse the project's real icon. The system owns the final rounded mask.
for iconset in (ENGINE/'Natives/Assets.xcassets').glob('AppIcon-*.appiconset'):
    shutil.copy2(REPO/'Assets/Brand/Icon.png', iconset/'Harbor-Icon.png')
    (iconset/'Contents.json').write_text(json.dumps({'images':[{'filename':'Harbor-Icon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}}))

info=ENGINE/'Natives/Info.plist';p=plistlib.loads(info.read_bytes())
p.update(CFBundleIdentifier='net.morben.harbor.ios',CFBundleDisplayName='MC Harbor',CFBundleName='MC Harbor',CFBundleShortVersionString='0.1.0',CFBundleVersion='1',MinimumOSVersion='16.0')
p['UIDeviceFamily']=[1,2]
p['NSLocalNetworkUsageDescription']='MC Harbor 使用本地网络发现局域网游戏和连接已授权的 AltServer。'
p['NSMicrophoneUsageDescription']='仅在你使用支持语音聊天的模组时，MC Harbor 才需要麦克风。'
p['CFBundleURLTypes']=[{'CFBundleURLName':'net.morben.harbor.ios.launch','CFBundleURLSchemes':['mcharbor','amethyst']}]
info.write_bytes(plistlib.dumps(p))
(BUILD/'patch-proof.json').write_text(json.dumps({'upstream':UPSTREAM,'platform':args.platform,'patches':patches,'privateStorage':True,'runtimeLicensesRetained':True},indent=2))
if args.prepare_only:
    print('Prepared pinned native engine:',ENGINE,flush=True);sys.exit(0)

run(['xcodegen','generate'],cwd=IOS)
derived=IOS/'build'/('ui-'+args.platform)
run(['xcodebuild','-project','MCHarborIOS.xcodeproj','-scheme','HarborIOSUI','-sdk',sdk,'-destination','generic/platform='+('iOS' if args.platform=='device' else 'iOS Simulator'),'-derivedDataPath',derived,'ARCHS=arm64','ONLY_ACTIVE_ARCH=NO','CODE_SIGNING_ALLOWED=NO','build'],cwd=IOS)
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
    import importlib.util
    spec=importlib.util.spec_from_file_location('simulator_archives',IOS/'tools/simulator-archives.py')
    archives=importlib.util.module_from_spec(spec);spec.loader.exec_module(archives)
    library_directory=ENGINE/'Natives/external/MobileGlues/src/main/cpp/libraries/ios'
    stub_report=[archives.retarget_tapi(stub) for stub in ENGINE.rglob('*.tbd')]
    archive_report=[archives.retarget_archive(path) for path in sorted(library_directory.glob('*.a'))]
    (EVIDENCE/'native-simulator-archive-adaptation.json').write_text(json.dumps({'archives':archive_report,'tapiStubs':stub_report},indent=2))
    for binary in list(macho_files(frameworks))+list(macho_files(ENGINE/'Natives/external/MobileGlues/src/main/cpp/libraries/ios')):
        run(['xcrun','vtool','-arch','arm64','-set-build-version','7','16.0','26.0','-replace','-output',binary,binary])
sdkpath=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()
java_home=os.environ.get('JAVA_HOME_8_ARM64') or os.environ.get('JAVA_HOME')
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
package=IOS/'build'/('MC-Harbor-iOS-0.1.0-preview.ipa' if args.platform=='device' else 'MC-Harbor-iOS-Simulator-0.1.0-preview.zip')
if package.exists(): package.unlink()
if args.platform=='device':
    with tempfile.TemporaryDirectory(prefix='harbor-package-',dir=BUILD) as staging:
        payload=Path(staging)/'Payload';payload.mkdir()
        run(['ditto',destination,payload/'MC Harbor.app'])
        run(['ditto','-c','-k','--keepParent',payload,package])
else:
    run(['ditto','-c','-k','--keepParent',destination,package])
with zipfile.ZipFile(package) as archive:
    executable=next(x for x in archive.infolist() if x.filename.endswith('.app/AngelAuraAmethyst'))
    assert stat.S_IMODE(executable.external_attr>>16)&0o111,'Packaged app lost its executable permissions'
    assert archive.testzip() is None,'Packaged app failed ZIP integrity verification'
with package.open('rb') as stream: digest=hashlib.file_digest(stream,'sha256').hexdigest()
report={'upstream':UPSTREAM,'platform':args.platform,'app':str(destination),'nativeExecutable':(destination/'AngelAuraAmethyst').is_file(),'frameworks':[x.name for x in (destination/'Frameworks').glob('Harbor*.framework')],'javaRuntimes':[x.name for x in (destination/'java_runtimes').iterdir() if x.is_dir()],'package':package.name,'packageBytes':package.stat().st_size,'packageSHA256':digest,'signing':'ad-hoc; device installation requires personal developer signing','minecraftGameplayVerified':False}
(EVIDENCE/('native-build-'+args.platform+'.json')).write_text(json.dumps(report,indent=2))
print(json.dumps(report),flush=True)
