#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "HarborAccountTokenStore.h"

// All Security calls are link-time fakes. This executable never touches a
// developer's or runner's real Keychain, while exercising production encoding.
static NSMutableDictionary *entries;
static OSStatus updateFailure = errSecSuccess, addFailure = errSecSuccess;
static BOOL duplicateRace;
static NSUInteger reads, updates, adds, deletes, checks;
#define CHECK(condition) do { checks++; if (!(condition)) { NSLog(@"FAILED line %d: %s", __LINE__, #condition); return 1; } } while (0)

OSStatus HBRTestCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    reads++;
    NSDictionary *item = (__bridge NSDictionary *)query;
    id data = entries[item[(id)kSecAttrAccount]];
    if (!data) return errSecItemNotFound;
    if (result) *result = CFBridgingRetain(data);
    return errSecSuccess;
}
OSStatus HBRTestUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    updates++;
    if (updateFailure != errSecSuccess) return updateFailure;
    NSString *key = ((__bridge NSDictionary *)query)[(id)kSecAttrAccount];
    if (!entries[key]) return errSecItemNotFound;
    entries[key] = ((__bridge NSDictionary *)attributes)[(id)kSecValueData];
    return errSecSuccess;
}
OSStatus HBRTestAdd(CFDictionaryRef query, CFTypeRef *result) {
    adds++;
    if (addFailure != errSecSuccess) return addFailure;
    NSDictionary *item = (__bridge NSDictionary *)query;
    NSString *key = item[(id)kSecAttrAccount];
    if (duplicateRace) { duplicateRace = NO; entries[key] = [NSData data]; return errSecDuplicateItem; }
    if (entries[key]) return errSecDuplicateItem;
    entries[key] = item[(id)kSecValueData];
    return errSecSuccess;
}
OSStatus HBRTestDelete(CFDictionaryRef query) {
    deletes++;
    [entries removeObjectForKey:((__bridge NSDictionary *)query)[(id)kSecAttrAccount]];
    return errSecSuccess;
}

int main(void) { @autoreleasepool {
    entries = [NSMutableDictionary dictionary];
    CHECK(HBRReadAccountTokens(nil) == nil);
    CHECK(!HBRStoreAccountTokens(@"", @"a", @"r"));
    HBRClearAccountTokens(nil);
    CHECK(reads == 0 && updates == 0 && adds == 0 && deletes == 0);
    CHECK(HBRStoreAccountTokens(@"qa-profile", @"initial-access", @"initial-refresh"));
    CHECK(adds == 1 && updates == 1 && deletes == 0);
    CHECK([HBRReadAccountTokens(@"qa-profile")[@"refreshToken"] isEqual:@"initial-refresh"]);
    CHECK(HBRStoreAccountTokens(@"qa-profile", @"new-access", @"new-refresh"));
    CHECK(adds == 1 && deletes == 0);
    CHECK([HBRReadAccountTokens(@"qa-profile")[@"accessToken"] isEqual:@"new-access"]);
    NSData *previous = entries[@"qa-profile"];
    updateFailure = errSecInteractionNotAllowed;
    CHECK(!HBRStoreAccountTokens(@"qa-profile", @"blocked-access", @"blocked-refresh"));
    CHECK([entries[@"qa-profile"] isEqual:previous] && deletes == 0);
    updateFailure = errSecSuccess;
    CHECK(!HBRStoreAccountTokens(@"qa-profile", nil, @"r"));
    CHECK(!HBRStoreAccountTokens(@"qa-profile", @"a", @""));
    CHECK([entries[@"qa-profile"] isEqual:previous]);
    entries[@"malformed"] = [@"not an archive" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK(HBRReadAccountTokens(@"malformed") == nil);
    entries[@"wrong-type"] = @"not data";
    CHECK(HBRReadAccountTokens(@"wrong-type") == nil);
    entries[@"incomplete"] = [NSKeyedArchiver archivedDataWithRootObject:@{@"accessToken":@"a"} requiringSecureCoding:YES error:nil];
    CHECK(HBRReadAccountTokens(@"incomplete") == nil);
    entries[@"oversize"] = [NSMutableData dataWithLength:1024 * 1024 + 1];
    CHECK(HBRReadAccountTokens(@"oversize") == nil);
    addFailure = errSecNotAvailable;
    CHECK(!HBRStoreAccountTokens(@"unavailable", @"a", @"r"));
    CHECK(entries[@"unavailable"] == nil);
    addFailure = errSecSuccess; duplicateRace = YES;
    CHECK(HBRStoreAccountTokens(@"race", @"race-a", @"race-r"));
    CHECK([HBRReadAccountTokens(@"race")[@"accessToken"] isEqual:@"race-a"]);
    HBRClearAccountTokens(@"qa-profile");
    CHECK(deletes == 1 && entries[@"qa-profile"] == nil);
    printf("Harbor account-token regression: %lu checks passed; real Keychain untouched.\n", (unsigned long)checks);
    return 0;
} }
