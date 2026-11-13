#import "HarborEngineAdapter.h"
#include <math.h>
#import <HarborIOSUI/HarborIOSUI-Swift.h>
#import "LauncherSplitViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherProfileEditorViewController.h"
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

@interface LauncherNavigationController (HarborLaunch)
- (void)reloadProfileList;
- (void)launchMinecraft:(id)sender;
@end

@interface HarborEngineAdapter : NSObject<HarborNativeServices>
@property(nonatomic,strong) LauncherSplitViewController *legacy;
@property(nonatomic,weak) SurfaceViewController *surface;
@property(nonatomic,weak) HarborGameTouchOverlay *overlay;
+ (instancetype)shared;
- (void)prepareTouchConfiguration;
@end

@interface HarborEnginePage : UIViewController
@property(nonatomic,strong) HarborEngineAdapter *adapter;
@property(nonatomic,copy) NSString *page;
@property(nonatomic,copy) NSString *profile;
@property(nonatomic) BOOL performedLaunch;
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
    if ([page isEqual:@"resources"]) return [[UINavigationController alloc] initWithRootViewController:[ModpackInstallViewController new]];
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
    if (![self.page isEqual:@"launch"] || self.performedLaunch) return;
    self.performedLaunch=YES;
    if (self.profile && PLProfiles.current.profiles[self.profile]) [PLProfiles.current setSelectedProfileName:self.profile];
    [self.adapter prepareTouchConfiguration];
    LauncherNavigationController *detail=(id)self.adapter.legacy.viewControllers.lastObject;
    [detail reloadProfileList];
    dispatch_async(dispatch_get_main_queue(), ^{ [detail launchMinecraft:nil]; });
}
@end

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
