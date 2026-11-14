#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

// Same app-specific, default-off key as the SwiftUI settings. Read at the
// action boundary so an already-open UIKit page honors a changed preference.
static inline BOOL HBRAnimationsEnabled(void) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"harbor.performance.exclusive"]) return NO;
#if TARGET_OS_IOS
    if (UIAccessibilityIsReduceMotionEnabled()) return NO;
#endif
    return YES;
}

static inline NSTimeInterval HBRAnimationDuration(NSTimeInterval duration) {
    return HBRAnimationsEnabled() ? duration : 0;
}
