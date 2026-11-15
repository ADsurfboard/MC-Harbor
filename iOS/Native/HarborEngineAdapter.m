#import "HarborEngineAdapter.h"
#include <math.h>
#import <HarborIOSUI/HarborIOSUI-Swift.h>
#import "LauncherSplitViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherProfileEditorViewController.h"
#import "LauncherProfilesViewController.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherPrefContCfgViewController.h"
#import "CustomControlsViewController.h"
#import "AccountListViewController.h"
#import "installer/ModpackInstallViewController.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "SurfaceViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "HarborModpackMetadata.h"
#import "HarborModArchive.h"

@interface LauncherNavigationController (HarborLaunch)
- (void)reloadProfileList;
- (void)launchMinecraft:(id)sender;
- (void)enterModInstaller;
- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter;
@end

@interface LauncherProfilesViewController (HarborInstall)
- (void)actionCreateFabricProfile;
- (void)actionCreateForgeProfile;
- (void)actionCreateModpackProfile;
- (void)actionEditProfile:(NSDictionary *)profile;
@end

@interface HarborEngineAdapter : NSObject<HarborNativeServices>
@property(nonatomic,strong) LauncherSplitViewController *legacy;
@property(nonatomic,strong) LauncherNavigationController *nativeLauncher;
@property(nonatomic,weak) SurfaceViewController *surface;
@property(nonatomic,weak) HarborGameTouchOverlay *overlay;
@property(nonatomic,copy) NSString *modAccessToken;
+ (instancetype)shared;
- (void)prepareTouchConfiguration;
- (LauncherNavigationController *)launcherController;
@end

@interface HarborEnginePage : UIViewController<UIDocumentPickerDelegate>
@property(nonatomic,strong) HarborEngineAdapter *adapter;
@property(nonatomic,copy) NSString *page;
@property(nonatomic,copy) NSString *profile;
@property(nonatomic) BOOL performedAction;
@property(nonatomic,strong) UILabel *importStatus;
@end

static BOOL lookInvertX = NO, lookInvertY = NO;
static double lookSensitivity = 1;
static __weak UIWindow *harborWindow;

@implementation HarborEngineAdapter
+ (instancetype)shared {
    static HarborEngineAdapter *instance; static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [HarborEngineAdapter new]; });
    return instance;
}
- (NSURL *)harborHomeURL {
    const char *home = getenv("AME_HOME");
    return [NSURL fileURLWithPath:home ? @(home) : NSHomeDirectory() isDirectory:YES];
}
- (NSString *)runtimeDescription { return @"iOS 原生 Java / 图形运行层 · Amethyst 开源内核"; }
- (void)readModArchiveAtURL:(NSURL *)url entry:(NSString *)entry completion:(void (^)(NSData *,NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        @autoreleasepool {
            NSError *error=nil;NSData *data=HBRReadModArchive(url,entry,&error);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(data,error.localizedDescription); });
        }
    });
}
- (NSData *)beginModAccessForProfile:(NSString *)profile error:(NSError **)error {
    return [self beginResourceAccessForProfile:profile kind:@"mods" error:error];
}
- (NSData *)beginResourceAccessForProfile:(NSString *)profile kind:(NSString *)kind error:(NSError **)error {
    NSString *failure=nil;
    if (![@[@"mods",@"resourcepacks",@"shaderpacks"] containsObject:kind]) failure=@"不支持此实例资源目录。";
    if (self.modAccessToken || (self.surface && self.surface.view.window) || UIApplication.sharedApplication.idleTimerDisabled)
        failure=@"请先停止游戏、等待下载完成，再操作实例中的模组文件。";
    NSDictionary *record=PLProfiles.current.profiles[profile];
    if (![record isKindOfClass:NSDictionary.class]) failure=@"实例已不存在，请返回游戏库刷新。";
    NSString *base=getPrefObject(@"general.game_directory");
    NSString *relative=[record[@"gameDir"] isKindOfClass:NSString.class] && [record[@"gameDir"] length] ? record[@"gameDir"]:@".";
    if (![base isKindOfClass:NSString.class] || !base.length || base.isAbsolutePath || base.pathComponents.count!=1 ||
        [base isEqual:@".."] || [base containsString:@"\\"] || [base containsString:@":"] || relative.isAbsolutePath ||
        [relative containsString:@"\\"] || [relative containsString:@":"] || [relative.pathComponents containsObject:@".."])
        failure=@"实例模组目录不在允许的存储范围内。";
    if (failure) {
        if (error) *error=[NSError errorWithDomain:@"net.morben.harbor.modaccess" code:1 userInfo:@{NSLocalizedDescriptionKey:failure}];
        return nil;
    }
    NSString *home=self.harborHomeURL.path.stringByResolvingSymlinksInPath;
    NSString *root=[[home stringByAppendingPathComponent:@"instances"] stringByAppendingPathComponent:base ?: @""];
    NSString *directory=[[[root stringByAppendingPathComponent:relative] stringByAppendingPathComponent:kind] stringByStandardizingPath];
    if (![directory hasPrefix:[root stringByAppendingString:@"/"]] || ![directory isEqual:directory.stringByResolvingSymlinksInPath])
        failure=@"实例模组目录包含越界路径或符号链接。";
    NSMutableArray *files=[NSMutableArray array];
    if (!failure && [NSFileManager.defaultManager fileExistsAtPath:directory]) {
        NSArray *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:error];
        if (!names) return nil;
        if (names.count>10000) failure=@"实例文件过多，请先在文件管理器中整理。";
        for (NSString *name in names) if ([name.pathExtension.lowercaseString isEqual:@"jar"]) {
            NSString *path=[directory stringByAppendingPathComponent:name];
            NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:error];
            if (!attributes) return nil;
            if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) { failure=@"实例模组中包含链接或非普通文件，已停止操作。"; break; }
            [files addObject:path];
        }
        if (files.count>4000) failure=@"一次最多管理 4000 个模组。";
    }
    if (failure) {
        if (error) *error=[NSError errorWithDomain:@"net.morben.harbor.modaccess" code:1 userInfo:@{NSLocalizedDescriptionKey:failure}];
        return nil;
    }
    NSString *token=NSUUID.UUID.UUIDString;
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"token":token,@"directory":directory,@"files":files} options:0 error:error];
    if (data) self.modAccessToken=token;
    return data;
}
- (void)endModAccessWithToken:(NSString *)token { if ([self.modAccessToken isEqual:token]) self.modAccessToken=nil; }
- (LauncherSplitViewController *)legacy {
    if (!_legacy) {
        _legacy = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
        [_legacy loadViewIfNeeded];
        for (UIViewController *controller in _legacy.viewControllers) {
            if ([controller isKindOfClass:LauncherNavigationController.class]) self.nativeLauncher=(id)controller;
        }
        _legacy.view.tintColor = [UIColor colorWithRed:0.12 green:0.52 blue:0.36 alpha:1];
    }
    return _legacy;
}
- (LauncherNavigationController *)launcherController {
    [self legacy];
    if (self.nativeLauncher) {
        [self.nativeLauncher loadViewIfNeeded];
        return self.nativeLauncher;
    }
    // The split view may collapse on iPhone. Do not assume a secondary index.
    NSMutableArray<UIViewController *> *pending = [NSMutableArray arrayWithObject:self.legacy];
    while (pending.count) {
        UIViewController *controller = pending.lastObject;
        [pending removeLastObject];
        if ([controller isKindOfClass:LauncherNavigationController.class]) {
            [controller loadViewIfNeeded]; // Register download/progress observers.
            self.nativeLauncher=(id)controller;
            return (id)controller;
        }
        [pending addObjectsFromArray:controller.childViewControllers];
    }
    return nil;
}
- (NSData *)instanceListJSON {
    [PLProfiles updateCurrent];
    NSMutableArray *result = [NSMutableArray array];
    NSDictionary *profiles = PLProfiles.current.profiles;
    for (NSString *key in [profiles.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        NSDictionary *profile = profiles[key];
        if (![profile isKindOfClass:NSDictionary.class]) continue;
        NSString *version = [profile[@"lastVersionId"] isKindOfClass:NSString.class] ? profile[@"lastVersionId"] : @"";
        NSString *loader = @"原版";
        NSString *gameVersion = version;
        NSString *path = [NSString stringWithFormat:@"%s/versions/%@/%@.json",getenv("GAME_DIR"),version,version];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if (![version containsString:@"/"] && ![version containsString:@"\\"] && ![version isEqual:@".."] && ![version isEqual:@"."] && [attributes[NSFileSize] unsignedLongLongValue] < 4 * 1024 * 1024) {
            NSData *data = [NSData dataWithContentsOfFile:path];
            id metadata = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([metadata isKindOfClass:NSDictionary.class] && [metadata[@"inheritsFrom"] isKindOfClass:NSString.class]) gameVersion=metadata[@"inheritsFrom"];
            NSArray *libraries = [metadata isKindOfClass:NSDictionary.class] && [metadata[@"libraries"] isKindOfClass:NSArray.class] ? metadata[@"libraries"] : @[];
            for (NSDictionary *library in libraries) {
                if (![library isKindOfClass:NSDictionary.class]) continue;
                NSString *name = [library[@"name"] isKindOfClass:NSString.class] ? library[@"name"] : @"";
                if ([name hasPrefix:@"net.neoforged:neoforge:"]) { loader=@"NeoForge"; break; }
                if ([name hasPrefix:@"org.quiltmc:quilt-loader:"]) { loader=@"Quilt"; break; }
                if ([name hasPrefix:@"net.fabricmc:fabric-loader:"]) { loader=@"Fabric"; break; }
                if ([name hasPrefix:@"net.minecraftforge:forge:"]) loader=@"Forge";
            }
        }
        [result addObject:@{@"id":key,@"name":[profile[@"name"] isKindOfClass:NSString.class] ? profile[@"name"] : key,@"version":version,@"gameVersion":gameVersion,@"loader":loader}];
    }
    return [NSJSONSerialization dataWithJSONObject:result options:0 error:nil] ?: [@"[]" dataUsingEncoding:NSUTF8StringEncoding];
}
- (UIViewController *)controllerForPage:(NSString *)page profile:(NSString *)profile {
    if (profile && PLProfiles.current.profiles[profile]) [PLProfiles.current setSelectedProfileName:profile];
    if ([page isEqual:@"accounts"]) {
        AccountListViewController *accounts = [AccountListViewController new];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:accounts];
        __weak UINavigationController *weakNav = nav;
        accounts.whenItemSelected = ^{ [weakNav dismissViewControllerAnimated:YES completion:nil]; };
        return nav;
    }
    if ([page isEqual:@"settings"]) return [[UINavigationController alloc] initWithRootViewController:[LauncherPreferencesViewController new]];
    if ([page isEqual:@"controls"]) return [[UINavigationController alloc] initWithRootViewController:[LauncherPrefContCfgViewController new]];
    if ([page isEqual:@"instance"] && profile && PLProfiles.current.profiles[profile]) {
        LauncherProfileEditorViewController *editor = [LauncherProfileEditorViewController new];
        // Cancel must not mutate the live profile before the player saves.
        editor.profile = [PLProfiles.current.profiles[profile] mutableCopy];
        return [[UINavigationController alloc] initWithRootViewController:editor];
    }
    HarborEnginePage *container = [HarborEnginePage new]; container.adapter=self; container.page=page; container.profile=profile;
    return container;
}
- (void)prepareTouchConfiguration {
    NSData *data = [HarborRootFactory controlConfigurationDataWithHome:self.harborHomeURL profile:PLProfiles.current.selectedProfileName];
    NSDictionary *layout = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *settings = layout[@"settings"];
    lookSensitivity = [settings[@"cameraSensitivity"] doubleValue];
    if (!isfinite(lookSensitivity) || lookSensitivity < 0.1 || lookSensitivity > 4) lookSensitivity=1;
    lookInvertX = [settings[@"invertCameraX"] boolValue]; lookInvertY = [settings[@"invertCameraY"] boolValue];
    setPrefBool(@"control.gyroscope_enable", [settings[@"gyroEnabled"] boolValue]);
    setPrefInt(@"control.gyroscope_sensitivity", (NSInteger)([settings[@"gyroSensitivity"] doubleValue] * 100));
    setPrefBool(@"control.gesture_hotbar", [settings[@"hotbarVisible"] boolValue]);
}
- (void)sendKey:(int32_t)key pressed:(BOOL)pressed {
    if (key>=32 && key<=348) CallbackBridge_nativeSendKey(key,0,pressed?1:0,0);
}
- (void)sendMouseButton:(int32_t)button pressed:(BOOL)pressed {
    if (button>=0 && button<=2) CallbackBridge_nativeSendMouseButton(button,pressed?1:0,0);
}
- (BOOL)isPointerGrabbed { return isGrabbing == JNI_TRUE; }
- (void)showGameKeyboard {
    id field = [self.surface valueForKey:@"inputTextField"];
    if ([field isKindOfClass:UITextField.class]) {
        if ([field isFirstResponder]) [field resignFirstResponder];
        else { [field becomeFirstResponder]; [field setText:@" "]; }
    }
}
@end

@implementation HarborEnginePage
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.systemBackgroundColor;
    UIViewController *legacy=self.adapter.legacy;
    if (legacy.parentViewController) { [legacy willMoveToParentViewController:nil]; [legacy.view removeFromSuperview]; [legacy removeFromParentViewController]; }
    [self addChildViewController:legacy]; legacy.view.frame=self.view.bounds;
    legacy.view.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:legacy.view]; [legacy didMoveToParentViewController:self];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.performedAction) return;
    self.performedAction=YES;
    LauncherNavigationController *detail=[self.adapter launcherController];
    if (!detail) { showDialog(@"无法打开运行层", @"请关闭当前页面后重试。"); return; }
    LauncherProfilesViewController *profiles = (id)detail.viewControllers.firstObject;
    if (![profiles isKindOfClass:LauncherProfilesViewController.class]) {
        profiles = [LauncherProfilesViewController new];
        [detail setViewControllers:@[profiles] animated:NO];
    }
    if ([self.page isEqual:@"resources"]) { [profiles actionCreateModpackProfile]; return; }
    if ([self.page isEqual:@"importPack"]) {
        UTType *pack=[UTType typeWithIdentifier:@"net.modrinth.mrpack"];
        UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:pack ? @[pack,UTTypeZIP]:@[UTTypeZIP] asCopy:NO];
        picker.delegate=self;picker.allowsMultipleSelection=NO;
        [self presentViewController:picker animated:YES completion:nil];return;
    }
    if ([self.page isEqual:@"fabric"]) { [profiles actionCreateFabricProfile]; return; }
    if ([self.page isEqual:@"forge"]) { [profiles actionCreateForgeProfile]; return; }
    if ([self.page isEqual:@"import"]) {
        UTType *jar=[UTType typeWithFilenameExtension:@"jar"] ?: UTTypeItem;
        UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[jar] asCopy:YES];
        picker.delegate=self;picker.allowsMultipleSelection=NO;
        // Present from the visible SwiftUI bridge, not a collapsed split column.
        [self presentViewController:picker animated:YES completion:nil];return;
    }
    if ([self.page isEqual:@"install"]) { [profiles actionEditProfile:@{@"name":@"", @"lastVersionId":@"latest-release"}]; return; }
    if (![self.page isEqual:@"launch"]) return;
    if (self.profile && PLProfiles.current.profiles[self.profile]) [PLProfiles.current setSelectedProfileName:self.profile];
    [self.adapter prepareTouchConfiguration];
    [detail reloadProfileList];
    dispatch_async(dispatch_get_main_queue(), ^{ [detail launchMinecraft:nil]; });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    UIViewController *host=self;
    while (host.parentViewController) host=host.parentViewController;
    [host.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *source=urls.firstObject;
    if (!source || !source.isFileURL) return;
    if ([self.page isEqual:@"import"]) {
        [[self.adapter launcherController] enterModInstallerWithPath:source.path hitEnterAfterWindowShown:NO];
        return;
    }
    NSString *storage=HBRNewModpackStorageName();
    NSURL *copy=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[storage stringByAppendingString:@".zip"]]];
    self.modalInPresentation=YES;
    UILabel *status=[UILabel new];status.numberOfLines=0;status.textAlignment=NSTextAlignmentCenter;
    status.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];status.adjustsFontForContentSizeCategory=YES;
    status.text=[NSString stringWithFormat:@"正在读取 %@\n原文件将保留，完成后显示逐项导入进度。",source.lastPathComponent];
    status.backgroundColor=UIColor.secondarySystemBackgroundColor;status.layer.cornerRadius=18;status.clipsToBounds=YES;
    status.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:status];self.importStatus=status;
    [NSLayoutConstraint activateConstraints:@[[status.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],
        [status.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20],
        [status.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor], [status.heightAnchor constraintGreaterThanOrEqualToConstant:120]]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        BOOL scoped=[source startAccessingSecurityScopedResource];
        __block NSError *failure=nil;NSError *coordination=nil;
        NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:source options:0 error:&coordination byAccessor:^(NSURL *readable) {
            NSDictionary *values=[readable resourceValuesForKeys:@[NSURLIsRegularFileKey,NSURLIsSymbolicLinkKey,NSURLFileSizeKey] error:&failure];
            unsigned long long size=[values[NSURLFileSizeKey] unsignedLongLongValue];
            if (!failure && (![values[NSURLIsRegularFileKey] boolValue] || [values[NSURLIsSymbolicLinkKey] boolValue] || !size || size>2ULL*1024*1024*1024))
                failure=[NSError errorWithDomain:@"net.morben.harbor.import" code:3 userInfo:@{NSLocalizedDescriptionKey:@"请选择不超过 2 GB 的 Modrinth 整合包文件。"}];
            NSDictionary *disk=!failure ? [NSFileManager.defaultManager attributesOfFileSystemForPath:NSTemporaryDirectory() error:&failure]:nil;
            if (!failure && [disk[NSFileSystemFreeSize] unsignedLongLongValue]<size+64*1024*1024)
                failure=[NSError errorWithDomain:@"net.morben.harbor.import" code:4 userInfo:@{NSLocalizedDescriptionKey:@"剩余空间不足，原文件没有修改。"}];
            if (!failure) [NSFileManager.defaultManager copyItemAtURL:readable toURL:copy error:&failure];
            NSDictionary *copied=!failure ? [NSFileManager.defaultManager attributesOfItemAtPath:copy.path error:&failure]:nil;
            if (!failure && [copied[NSFileSize] unsignedLongLongValue]!=size)
                failure=[NSError errorWithDomain:@"net.morben.harbor.import" code:5 userInfo:@{NSLocalizedDescriptionKey:@"文件读取未完成，请重新选择。"}];
        }];
        if (scoped) [source stopAccessingSecurityScopedResource];
        failure=failure ?: coordination;
        dispatch_async(dispatch_get_main_queue(),^{
            self.modalInPresentation=NO;[self.importStatus removeFromSuperview];self.importStatus=nil;
            if (failure || !self.view.window) {
                [NSFileManager.defaultManager removeItemAtURL:copy error:nil];
                if (self.view.window) showDialog(@"无法导入整合包",failure.localizedDescription ?: @"导入页面已关闭。");return;
            }
            [NSNotificationCenter.defaultCenter postNotificationName:@"HarborInstallLocalModpack" object:nil userInfo:@{@"path":copy.path,@"storage":storage}];
        });
    });
}
@end

UIViewController *HBRLauncherController(void) {
    return [HarborEngineAdapter.shared launcherController];
}
BOOL HBRCanLaunchGame(void) { return HarborEngineAdapter.shared.modAccessToken == nil; }
void HBRRegisterLauncherController(UIViewController *controller) {
    if ([controller isKindOfClass:LauncherNavigationController.class]) HarborEngineAdapter.shared.nativeLauncher=(id)controller;
}
UIViewController *HBRVisibleController(Class type) {
    NSMutableArray *pending=[NSMutableArray array];
    if (harborWindow.rootViewController) [pending addObject:harborWindow.rootViewController];
    while (pending.count) {
        UIViewController *controller=pending.lastObject;[pending removeLastObject];
        if ([controller isKindOfClass:type] && controller.viewIfLoaded.window) return controller;
        [pending addObjectsFromArray:controller.childViewControllers];
        if (controller.presentedViewController) [pending addObject:controller.presentedViewController];
    }
    return nil;
}

void HBRInstallRoot(UIWindow *window) {
    harborWindow=window;
    window.rootViewController=[HarborRootFactory makeControllerWithServices:HarborEngineAdapter.shared];
}
void HBRInstallGameControls(UIViewController *controller) {
    if (![controller isKindOfClass:SurfaceViewController.class]) return;
    SurfaceViewController *surface=(id)controller;
    HarborEngineAdapter *adapter=HarborEngineAdapter.shared;
    [adapter.overlay cancelAllInputs]; [adapter.overlay removeFromSuperview];
    adapter.surface=surface; [adapter prepareTouchConfiguration];
    [surface performSelector:@selector(updatePreferenceChanges)];
    [surface.ctrlView removeFromSuperview];
    adapter.overlay=[HarborRootFactory installGameControlsOn:surface.rootView services:adapter profile:PLProfiles.current.selectedProfileName];
    [HarborRootFactory gameDidStartWithServices:adapter profile:PLProfiles.current.selectedProfileName ?: @""];
}
void HBRNotifyGameStopped(void) {
    [HarborEngineAdapter.shared.overlay cancelAllInputs];
    [HarborRootFactory gameDidStop];
}
void HBRUpdateGameGrabState(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [HarborEngineAdapter.shared.overlay updateGrabState:isGrabbing == JNI_TRUE]; });
}
CGPoint HBRApplyLookDelta(CGPoint delta) {
    delta.x *= lookSensitivity * (lookInvertX ? -1 : 1);
    delta.y *= lookSensitivity * (lookInvertY ? -1 : 1);
    return delta;
}
