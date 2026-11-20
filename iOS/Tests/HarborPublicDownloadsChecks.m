#import <Foundation/Foundation.h>
#import "HarborPublicDownloads.h"
static NSUInteger checks;
static void Check(BOOL okay,NSString *message) { checks++;if(!okay){NSLog(@"FAILED: %@",message);exit(1);} }
static NSMutableArray<NSURLRequest *> *requests;
static NSLock *lock;
@interface PublicFixtureProtocol : NSURLProtocol @end
@implementation PublicFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)stopLoading {}
- (void)startLoading {
    [lock lock];[requests addObject:self.request];[lock unlock];
    NSString *path=self.request.URL.path;BOOL mirror=[self.request.URL.host isEqual:@"bmclapi2.bangbang93.com"];
    if (mirror && [path hasSuffix:@"timeout"]) { [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]];return; }
    NSInteger status=[path hasSuffix:@"missing"] || (mirror && [path hasSuffix:@"fallback"]) ? 503:200;
    NSString *text=@"[{\"version\":\"0.16.0\",\"stable\":true}]";
    if (mirror && [path hasSuffix:@"badjson"]) text=@"<html>not json</html>";
    if (mirror && [path hasSuffix:@"badshape"]) text=@"[\"not a version object\"]";
    if ([path containsString:@"version_manifest"]) {
        NSString *version=mirror ? @"../other-instance":@"1.20.1";
        text=[NSString stringWithFormat:@"{\"versions\":[{\"id\":\"%@\",\"type\":\"release\",\"url\":\"https://piston-meta.mojang.com/version.json\"}],\"latest\":{\"release\":\"%@\",\"snapshot\":\"%@\"}}",version,version,version];
    }
    if ([path hasSuffix:@"maven-metadata.xml"]) text=mirror ? @"<broken>":@"<metadata><versioning><versions><version>1.0</version></versions></versioning></metadata>";
    if ([path hasSuffix:@"entity.xml"]) text=@"<!DOCTYPE x [<!ENTITY payload 'should not expand'>]><x>&payload;</x>";
    NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding];
    NSString *length=[path hasSuffix:@"oversize"] ? @"8388609":@(data.length).stringValue;
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Length":length,@"Content-Type":@"application/json"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];[self.client URLProtocolDidFinishLoading:self];
}
@end
static void Fetch(NSString *path,HBRMetadataFormat format,BOOL success,NSUInteger attempts) {
    [lock lock];[requests removeAllObjects];[lock unlock];
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.protocolClasses=@[PublicFixtureProtocol.class];config.HTTPAdditionalHeaders=@{@"Authorization":@"fixture-secret-must-not-leave",@"Cookie":@"fixture-cookie"};
    __block BOOL finished=NO;__block NSUInteger calls=0;
    HBRFetchPublicMetadata([NSURL URLWithString:[@"https://meta.fabricmc.net/" stringByAppendingString:path]],format,@"domesticFirst",config,^(id object,NSError *error){
        calls++;Check(success ? object!=nil && error==nil:object==nil && error!=nil,@"metadata result / fallback");finished=YES;
    });
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:8];
    while(!finished && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(finished && calls==1,@"completion exactly once");
    [lock lock];NSArray *captured=[requests copy];[lock unlock];
    Check(captured.count==attempts,@"bounded retry count");
    for(NSURLRequest *request in captured){
        Check([request.URL.scheme isEqual:@"https"],@"TLS preserved");
        Check([request.HTTPMethod isEqual:@"GET"] && request.HTTPBody==nil,@"public GET only");
        Check([request valueForHTTPHeaderField:@"Authorization"]==nil && [request valueForHTTPHeaderField:@"Cookie"]==nil,@"credentials never forwarded");
    }
}
int main(void) { @autoreleasepool {
    lock=[NSLock new];requests=[NSMutableArray new];
    NSDictionary *routes=@{
        @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json":@"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json",
        @"https://piston-data.mojang.com/v1/objects/abc/client.jar":@"https://bmclapi2.bangbang93.com/v1/objects/abc/client.jar",
        @"http://resources.download.minecraft.net/ab/abcdef":@"https://bmclapi2.bangbang93.com/assets/ab/abcdef",
        @"https://libraries.minecraft.net/a/b.jar":@"https://bmclapi2.bangbang93.com/maven/a/b.jar",
        @"https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml":@"https://bmclapi2.bangbang93.com/maven/net/neoforged/neoforge/maven-metadata.xml",
        @"https://meta.fabricmc.net/v2/versions/game":@"https://bmclapi2.bangbang93.com/fabric-meta/v2/versions/game",
        @"https://cdn.modrinth.com/data/a/versions/b/mod.jar":@"https://mod.mcimirror.top/data/a/versions/b/mod.jar",
        @"https://repo1.maven.org/maven2/org/qa/lib.jar":@"https://mirrors.cloud.tencent.com/nexus/repository/maven-public/org/qa/lib.jar"};
    for(NSString *original in routes){
        NSArray<NSURL *> *first=HBRPublicDownloadURLs([NSURL URLWithString:original],@"domesticFirst");
        Check(first.count==2 && [first[0].absoluteString isEqual:routes[original]],@"exact host / path mapping");
        NSArray *reversed=HBRPublicDownloadURLs([NSURL URLWithString:original],@"officialFirst");
        Check([reversed isEqual:@[first[1],first[0]]],@"official-first preference");
        Check([first[1].scheme isEqual:@"https"],@"legacy public HTTP upgraded");
    }
    for(NSString *url in @[@"https://api.minecraftservices.com/minecraft/profile",@"https://account.example/authserver/authenticate",@"https://meta.fabricmc.net.evil.example/v2/versions/game",@"https://user:password@meta.fabricmc.net/v2/versions/game",@"https://meta.fabricmc.net:8443/v2/versions/game",@"https://meta.fabricmc.net/v2/versions/game?token=private"]){
        NSArray *values=HBRPublicDownloadURLs([NSURL URLWithString:url],@"domesticFirst");
        Check(values.count==1 && [values[0] isEqual:[NSURL URLWithString:url]],@"unrelated / credential-bearing URLs stay on original host");
    }
    for(NSString *path in @[@"fallback",@"timeout",@"badjson",@"badshape"])Fetch(path,HBRMetadataArray,YES,2);
    Fetch(@"version_manifest_v2.json",HBRMetadataDictionary,YES,2);
    Fetch(@"maven-metadata.xml",HBRMetadataXML,YES,2);
    Fetch(@"missing",HBRMetadataArray,NO,2);Fetch(@"oversize",HBRMetadataArray,NO,2);Fetch(@"entity.xml",HBRMetadataXML,NO,2);
    printf("PASS: %lu real Foundation download-route / NSURLSession metadata checks; no network, player data, preferences or credentials used.\n",(unsigned long)checks);
}return 0; }
