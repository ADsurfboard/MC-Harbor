#import "HarborAccountTokenStore.h"
#import <Security/Security.h>

static BOOL HBRNonemptyString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0;
}

static NSDictionary *HBRTokenQuery(NSString *profile) {
    if (!HBRNonemptyString(profile)) return nil;
    return @{(id)kSecClass:(id)kSecClassGenericPassword,
             (id)kSecAttrService:@"AccountToken", (id)kSecAttrAccount:profile};
}

NSDictionary *HBRReadAccountTokens(NSString *profile) {
    NSDictionary *query = HBRTokenQuery(profile);
    if (!query) return nil;
    NSMutableDictionary *readQuery = query.mutableCopy;
    readQuery[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
    readQuery[(id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)readQuery, &result);
    id data = CFBridgingRelease(result);
    if (status != errSecSuccess || ![data isKindOfClass:NSData.class] || [data length] > 1024 * 1024) return nil;
    NSError *error = nil;
    NSDictionary *tokens;
    @try {
        tokens = [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithObjects:NSDictionary.class, NSString.class, nil]
                                                   fromData:data error:&error];
    } @catch (NSException *exception) {
        return nil;
    }
    if (error || ![tokens isKindOfClass:NSDictionary.class] ||
        !HBRNonemptyString(tokens[@"accessToken"]) || !HBRNonemptyString(tokens[@"refreshToken"])) return nil;
    return tokens;
}

BOOL HBRStoreAccountTokens(NSString *profile, NSString *accessToken, NSString *refreshToken) {
    NSDictionary *query = HBRTokenQuery(profile);
    if (!query || !HBRNonemptyString(accessToken) || !HBRNonemptyString(refreshToken)) return NO;
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:@{@"accessToken":accessToken, @"refreshToken":refreshToken}
                                      requiringSecureCoding:YES error:&error];
    if (!data || error || data.length > 1024 * 1024) return NO;
    NSDictionary *attributes = @{(id)kSecValueData:data,
                                (id)kSecAttrAccessible:(id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    if (status != errSecItemNotFound) return status == errSecSuccess;
    NSMutableDictionary *addition = query.mutableCopy;
    [addition addEntriesFromDictionary:attributes];
    status = SecItemAdd((__bridge CFDictionaryRef)addition, NULL);
    // Another request may have created the entry between update and add.
    if (status == errSecDuplicateItem) {
        status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    }
    return status == errSecSuccess;
}

void HBRClearAccountTokens(NSString *profile) {
    NSDictionary *query = HBRTokenQuery(profile);
    if (query) SecItemDelete((__bridge CFDictionaryRef)query);
}
