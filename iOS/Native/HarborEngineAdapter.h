#import <UIKit/UIKit.h>
void HBRInstallRoot(UIWindow *window);
void HBRInstallGameControls(UIViewController *controller);
void HBRUpdateGameGrabState(void);
CGPoint HBRApplyLookDelta(CGPoint delta);
UIViewController *HBRLauncherController(void);
BOOL HBRCanLaunchGame(void);
void HBRRegisterLauncherController(UIViewController *controller);
UIViewController *HBRVisibleController(Class type);
