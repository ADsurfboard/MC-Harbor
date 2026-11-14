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

@interface LauncherNavigationController (HarborLaunch)
- (void)reloadProfileList;
- (void)launchMinecraft:(id)sender;
- (void)enterModInstaller;
@end

@interface LauncherProfilesViewController (HarborInstall)
- (void)actionCreateFabricProfile;
- (void)actionCreateForgeProfile;
- (void)actionCreateModpackProfile;
- (void)actionEditProfile:(NSDictionary *)profile;
@end

@interface HarborEngineAdapter : NSObject<HarborNativeServices>
@property(nonatomic,strong) LauncherSplitViewController *legacy;
@property(nonatomic,weak) SurfaceViewController *surface;
@property(nonatomic,weak) HarborGameTouchOverlay *overlay;
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
- (LauncherSplitViewController *)legacy {
    if (!_legacy) {
        _legacy = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
        [_legacy loadViewIfNeeded];
        _legacy.view.tintColor = [UIColor colorWithRed:0.12 green:0.52 blue:0.36 alpha:1];
    }
    return _legacy;
}
- (LauncherNavigationController *)launcherController {
    // The split view may collapse on iPhone. Do not assume a secondary index.
    NSMutableArray<UIViewController *> *pending = [NSMutableArray arrayWithObject:self.legacy];
    while (pending.count) {
        UIViewController *controller = pending.lastObject;
        [pending removeLastObject];
        if ([controller isKindOfClass:LauncherNavigationController.class]) {
            [controller loadViewIfNeeded]; // Register download/progress observers.
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
        NSString *path = [NSString stringWithFormat:@"%s/versions/%@/%@.json",getenv("GAME_DIR"),version,version];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if (![version containsString:@"/"] && ![version containsString:@"\\"] && ![version isEqual:@".."] && ![version isEqual:@"."] && [attributes[NSFileSize] unsignedLongLongValue] < 4 * 1024 * 1024) {
            NSData *data = [NSData dataWithContentsOfFile:path];
            id metadata = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
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
        [result addObject:@{@"id":key,@"name":[profile[@"name"] isKindOfClass:NSString.class] ? profile[@"name"] : key,@"version":version,@"loader":loader}];
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
    if ([self.page isEqual:@"import"]) { [detail enterModInstaller]; return; }
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

void HBRInstallRoot(UIWindow *window) {
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
}
void HBRUpdateGameGrabState(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [HarborEngineAdapter.shared.overlay updateGrabState:isGrabbing == JNI_TRUE]; });
}
CGPoint HBRApplyLookDelta(CGPoint delta) {
    delta.x *= lookSensitivity * (lookInvertX ? -1 : 1);
    delta.y *= lookSensitivity * (lookInvertY ? -1 : 1);
    return delta;
}
