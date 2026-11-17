#import "HarborPublicDownloads.h"

NSString *HBRPublicDownloadRoute(void) {
    return [NSUserDefaults.standardUserDefaults stringForKey:@"harbor.ios.resources.route"] ?: @"domesticFirst";
}
NSArray<NSURL *> *HBRPublicDownloadURLs(NSURL *original, NSString *route) {
    if (!original || original.user || original.password || (original.port && original.port.integerValue!=443)) return original ? @[original]:@[];
    NSURLComponents *parts=[NSURLComponents componentsWithURL:original resolvingAgainstBaseURL:NO];
    if (parts.query.length) return @[original];
    if (![@[@"https",@"http"] containsObject:parts.scheme.lowercaseString]) return @[original];
    NSString *host=parts.host.lowercaseString,*path=parts.percentEncodedPath,*prefix=nil;
    NSString *mirrorHost=@"bmclapi2.bangbang93.com";
    if ([@[@"piston-meta.mojang.com",@"piston-data.mojang.com",@"launchermeta.mojang.com",@"launcher.mojang.com"] containsObject:host]) prefix=@"";
    else if ([host isEqual:@"resources.download.minecraft.net"]) prefix=@"/assets";
    else if ([@[@"libraries.minecraft.net",@"maven.minecraftforge.net",@"maven.fabricmc.net"] containsObject:host]) prefix=@"/maven";
    else if ([host isEqual:@"maven.neoforged.net"] && [path hasPrefix:@"/releases/"]) { prefix=@"/maven";path=[path substringFromIndex:9]; }
    else if ([host isEqual:@"meta.fabricmc.net"]) prefix=@"/fabric-meta";
    else if ([host isEqual:@"cdn.modrinth.com"]) { prefix=@"";mirrorHost=@"mod.mcimirror.top"; }
    else if ([@[@"repo1.maven.org",@"repo.maven.apache.org"] containsObject:host] && [path hasPrefix:@"/maven2/"]) { prefix=@"/nexus/repository/maven-public";path=[path substringFromIndex:7];mirrorHost=@"mirrors.cloud.tencent.com"; }
    if (!prefix) return @[original];
    // Upgrade old public asset URLs; never downgrade TLS or perform substring
    // replacements that could redirect an unrelated or authenticated hostname.
    parts.scheme=@"https";NSURL *official=parts.URL;
    parts.host=mirrorHost;parts.percentEncodedPath=[prefix stringByAppendingString:path];
    NSURL *mirror=parts.URL;
    if (!mirror || !official || [mirror isEqual:official]) return official ? @[official]:@[original];
    return [route isEqual:@"officialFirst"] ? @[official,mirror]:@[mirror,official];
}

static NSError *HBRMetadataError(NSString *message) {
    return [NSError errorWithDomain:@"net.morben.harbor.publicdownload" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
@interface HBRPublicMetadata : NSObject<NSURLSessionDataDelegate,NSXMLParserDelegate>
@property NSArray<NSURL *> *urls;
@property NSUInteger attempt,redirects;
@property HBRMetadataFormat format;
@property NSURLSessionConfiguration *configuration;
@property NSURLSession *session;
@property NSURLSessionDataTask *task;
@property NSMutableData *bytes;
@property NSError *failure;
@property(copy) void (^completion)(id,NSError *);
- (void)start;
@end
@implementation HBRPublicMetadata
- (void)finish:(id)object error:(NSError *)error {
    void (^completion)(id,NSError *)=self.completion;self.completion=nil;
    [self.session finishTasksAndInvalidate];self.session=nil;self.task=nil;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(object,error); });
}
- (void)start {
    if (self.attempt>=self.urls.count) { [self finish:nil error:self.failure ?: HBRMetadataError(@"官方与镜像来源均无法读取，请检查网络后重试。")];return; }
    NSURL *url=self.urls[self.attempt++];self.bytes=[NSMutableData new];self.redirects=0;self.failure=nil;
    NSURLSessionConfiguration *config=[self.configuration copy] ?: NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest=15;config.timeoutIntervalForResource=35;
    config.URLCache=nil;config.URLCredentialStorage=nil;config.HTTPCookieStorage=nil;config.HTTPShouldSetCookies=NO;
    config.HTTPAdditionalHeaders=@{@"User-Agent":@"MC-Harbor-iOS/0.1 (+https://github.com/ADsurfboard/MC-Harbor)"};
    NSOperationQueue *queue=[NSOperationQueue new];queue.maxConcurrentOperationCount=1;
    self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:queue];
    self.task=[self.session dataTaskWithURL:url];[self.task resume];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))done {
    BOOL valid=[response isKindOfClass:NSHTTPURLResponse.class] && ((NSHTTPURLResponse *)response).statusCode==200 && response.expectedContentLength<=8*1024*1024;
    if (!valid) self.failure=HBRMetadataError(@"下载来源返回错误状态或元数据超过 8 MB。");
    done(valid ? NSURLSessionResponseAllow:NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (data.length>8*1024*1024 || self.bytes.length>8*1024*1024-data.length) { self.failure=HBRMetadataError(@"元数据超过 8 MB，已停止读取。");[task cancel];return; }
    [self.bytes appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (task!=self.task) return;
    error=self.failure ?: error;id object=nil;
    if (!error) {
        if (self.format==HBRMetadataXML) {
            NSXMLParser *parser=[[NSXMLParser alloc] initWithData:self.bytes];parser.shouldResolveExternalEntities=NO;parser.delegate=self;
            if ([parser parse]) object=[self.bytes copy];else error=parser.parserError ?: HBRMetadataError(@"加载器 XML 元数据格式无效。");
        } else {
            object=[NSJSONSerialization JSONObjectWithData:self.bytes options:0 error:&error];
            Class expected=self.format==HBRMetadataArray ? NSArray.class:NSDictionary.class;
            if (object && ![object isKindOfClass:expected]) error=HBRMetadataError(@"加载器 JSON 元数据结构无效。");
            if (!error && self.format==HBRMetadataArray) for (id row in object) {
                if (![row isKindOfClass:NSDictionary.class] || ![row[@"version"] isKindOfClass:NSString.class]) { error=HBRMetadataError(@"加载器版本条目无效。");break; }
            }
            if (!error && [task.originalRequest.URL.path containsString:@"version_manifest"]) {
                if (![object[@"versions"] isKindOfClass:NSArray.class] || ![object[@"latest"] isKindOfClass:NSDictionary.class]) error=HBRMetadataError(@"Minecraft 版本索引不完整。");
            }
            if (!error && [task.originalRequest.URL.path hasSuffix:@"/profile/json"]) {
                if (![object[@"id"] isKindOfClass:NSString.class] || ![object[@"libraries"] isKindOfClass:NSArray.class] || ![object[@"mainClass"] isKindOfClass:NSString.class]) error=HBRMetadataError(@"加载器启动配置不完整。");
            }
        }
    }
    if (error) { self.failure=error;[session finishTasksAndInvalidate];self.session=nil;self.task=nil;[self start]; }
    else [self finish:object error:nil];
}
- (void)parser:(NSXMLParser *)parser foundExternalEntityDeclarationWithName:(NSString *)name publicID:(NSString *)publicID systemID:(NSString *)systemID { [parser abortParsing]; }
- (void)parser:(NSXMLParser *)parser foundInternalEntityDeclarationWithName:(NSString *)name value:(NSString *)value { [parser abortParsing]; }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))done {
    NSURL *url=request.URL;
    BOOL valid=++self.redirects<=6 && [url.scheme.lowercaseString isEqual:@"https"] && !url.user && !url.password && (!url.port || url.port.integerValue==443);
    if (!valid) { self.failure=HBRMetadataError(@"下载来源重定向无效。");done(nil);return; }
    // A new request: assigning allHTTPHeaderFields keeps headers it does not name.
    NSMutableURLRequest *safe=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    safe.HTTPShouldHandleCookies=NO;[safe setValue:@"MC-Harbor-iOS/0.1" forHTTPHeaderField:@"User-Agent"];done(safe);
}
@end

void HBRFetchPublicMetadata(NSURL *url,HBRMetadataFormat format,NSString *route,NSURLSessionConfiguration *configuration,void (^completion)(id,NSError *)) {
    if (!url || ![url.scheme.lowercaseString isEqual:@"https"] || url.user || url.password || (url.port && url.port.integerValue!=443)) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil,HBRMetadataError(@"公共元数据地址须为有效 HTTPS 地址。")); });return; }
    HBRPublicMetadata *request=[HBRPublicMetadata new];request.urls=HBRPublicDownloadURLs(url,route ?: HBRPublicDownloadRoute());request.format=format;request.configuration=configuration;request.completion=completion;[request start];
}
void HBRPublicGET(NSString *url,HBRMetadataFormat format,void (^success)(NSURLSessionTask *,id),void (^failure)(NSURLSessionTask *,NSError *)) {
    HBRFetchPublicMetadata([NSURL URLWithString:url],format,nil,nil,^(id object,NSError *error) {
        if (error) { if(failure)failure(nil,error); } else if(success)success(nil,object);
    });
}
NSData *HBRReadPublicXML(NSURL *url,NSError **error) {
    if (NSThread.isMainThread) { if(error)*error=HBRMetadataError(@"加载器 XML 须在后台读取。");return nil; }
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSData *data;__block NSError *failure;NSObject *gate=[NSObject new];
    HBRFetchPublicMetadata(url,HBRMetadataXML,nil,nil,^(id object,NSError *error){@synchronized(gate){data=object;failure=error;}dispatch_semaphore_signal(done);});
    BOOL timeout=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,75*NSEC_PER_SEC))!=0;
    @synchronized(gate){if(timeout)failure=HBRMetadataError(@"加载器元数据读取超时，请检查网络后重试。");if(error)*error=failure;return failure ? nil:data;}
}
