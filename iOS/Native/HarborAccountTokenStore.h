#import <Foundation/Foundation.h>

// Keep the pinned engine's existing Keychain service and account identifiers.
// Never return partially decoded credentials or replace a token by deleting it.
FOUNDATION_EXPORT NSDictionary *HBRReadAccountTokens(NSString *profile);
FOUNDATION_EXPORT BOOL HBRStoreAccountTokens(NSString *profile, NSString *accessToken, NSString *refreshToken);
FOUNDATION_EXPORT void HBRClearAccountTokens(NSString *profile);
