#import <Foundation/Foundation.h>
#import "HarborMotion.h"

int main(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSDictionary *original = [defaults volatileDomainForName:NSArgumentDomain];
        NSMutableDictionary *arguments = original.mutableCopy ?: [NSMutableDictionary new];
        int count = 0;
#define CHECK(value) do { if (!(value)) { NSLog(@"FAIL %s", #value); return 1; } count++; } while(0)
        // Volatile overrides affect only this disposable process, not the
        // developer's launcher settings or any persistent preferences.
        arguments[@"harbor.performance.exclusive"] = @NO;
        [defaults setVolatileDomain:arguments forName:NSArgumentDomain];
        CHECK(HBRAnimationsEnabled());
        CHECK(HBRAnimationDuration(0.35) == 0.35);
        CHECK(HBRAnimationDuration(0) == 0);
        arguments[@"harbor.performance.exclusive"] = @YES;
        [defaults setVolatileDomain:arguments forName:NSArgumentDomain];
        CHECK(!HBRAnimationsEnabled());
        CHECK(HBRAnimationDuration(0.35) == 0);
        CHECK(HBRAnimationDuration(1.2) == 0);
        arguments[@"harbor.performance.exclusive"] = @NO;
        [defaults setVolatileDomain:arguments forName:NSArgumentDomain];
        CHECK(HBRAnimationsEnabled());
        CHECK(HBRAnimationDuration(1.2) == 1.2);
        [defaults setVolatileDomain:original ?: @{} forName:NSArgumentDomain];
        printf("PASS %d native motion policy checks\n", count);
    }
    return 0;
}
