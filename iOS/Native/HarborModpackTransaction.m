#import "HarborModpackTransaction.h"
#import "HarborModpackMetadata.h"

static NSError *HBRImportError(NSString *message) {
    return [NSError errorWithDomain:@"net.morben.harbor.import" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSError *HBRCancelled(void) { return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]; }

// Native download tasks stream to a temporary file. The transaction checks its
// size and hash before considering it complete or moving to another URL.
@interface HBRImportHTTP : NSObject<NSURLSessionDownloadDelegate>
@property NSURLSession *session;
@property NSURLSessionDownloadTask *task;
@property NSURL *target;
@property(copy) void (^completion)(NSError *);
@property NSUInteger redirects;
@property unsigned long long expectedBytes;
@property NSError *failure;
@property BOOL produced;
- (void)start:(NSURL *)url;
@end
@implementation HBRImportHTTP
- (void)start:(NSURL *)url {
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest=30; config.timeoutIntervalForResource=180;
    config.URLCache=nil; config.HTTPCookieStorage=nil;
    config.HTTPAdditionalHeaders=@{@"User-Agent":@"MC-Harbor/0.1 (+https://github.com/ADsurfboard/MC-Harbor)"};
    NSOperationQueue *callbacks=[NSOperationQueue new];callbacks.maxConcurrentOperationCount=1;
    self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:callbacks];
    self.task=[self.session downloadTaskWithURL:url];
    [self.task resume];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytes totalBytesWritten:(int64_t)written totalBytesExpectedToWrite:(int64_t)expected {
    if (written<0 || (unsigned long long)written>self.expectedBytes || (expected>0 && (unsigned long long)expected>self.expectedBytes)) {
        self.failure=HBRImportError(@"下载数据超过整合包声明的大小。");[task cancel];
    }
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    NSError *error=self.failure;NSURLResponse *response=task.response;
    if (!error && (![response isKindOfClass:NSHTTPURLResponse.class] || [(NSHTTPURLResponse *)response statusCode]!=200)) error=HBRImportError(@"下载服务器未返回完整文件。");
    NSDictionary *attributes=!error ? [NSFileManager.defaultManager attributesOfItemAtPath:location.path error:&error]:nil;
    if (!error && [attributes[NSFileSize] unsignedLongLongValue]!=self.expectedBytes) error=HBRImportError(@"下载文件大小不匹配。");
    if (!error) [NSFileManager.defaultManager createDirectoryAtURL:self.target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
    if (!error) self.produced=[NSFileManager.defaultManager moveItemAtURL:location toURL:self.target error:&error];
    self.failure=error;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    error=self.failure ?: error;
    if (!error && !self.produced) error=HBRImportError(@"下载未生成临时文件。");
    void (^done)(NSError *)=self.completion;self.completion=nil;
    [self.session finishTasksAndInvalidate];self.session=nil;self.task=nil;
    if (done) done(error);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    NSURL *url=request.URL;
    NSSet *hosts=[NSSet setWithArray:@[@"cdn.modrinth.com",@"github.com",@"raw.githubusercontent.com",@"gitlab.com",@"release-assets.githubusercontent.com",@"objects.githubusercontent.com",@"github-releases.githubusercontent.com"]];
    BOOL valid=++self.redirects<=8 && [url.scheme.lowercaseString isEqual:@"https"] && url.host.length && [hosts containsObject:url.host.lowercaseString] && !url.user && !url.password && (!url.port || url.port.integerValue==443);
    completionHandler(valid ? request:nil);
}
@end

@interface HBRModpackTransaction ()
@property NSProgress *progress;
@property NSURL *destination,*stage;
@property NSArray<NSDictionary *> *files;
@property(copy) HBRImportStageAction apply,commit;
@property(copy) void (^completion)(NSError *);
@property dispatch_queue_t queue;
@property NSMutableDictionary<NSNumber *,HBRImportCancel> *active;
@property NSMutableDictionary<NSNumber *,NSNumber *> *attempts;
@property NSMutableDictionary<NSNumber *,NSUUID *> *tickets;
@property NSError *failure;
@property NSUInteger next,finished;
@property BOOL started,ended,ownsStage,ownsDestination;
@end

@implementation HBRModpackTransaction
- (instancetype)initWithDestination:(NSURL *)destination files:(NSArray<NSDictionary *> *)files applyOverrides:(HBRImportStageAction)apply commit:(HBRImportStageAction)commit completion:(void (^)(NSError *))completion {
    if ((self=[super init])) {
        _destination=destination.URLByStandardizingPath;
        _stage=[destination.URLByDeletingLastPathComponent URLByAppendingPathComponent:[@".import-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        _files=[files copy];_apply=[apply copy];_commit=[commit copy];_completion=[completion copy];
        _queue=dispatch_queue_create("net.morben.harbor.import",DISPATCH_QUEUE_SERIAL);
        _active=[NSMutableDictionary new];_attempts=[NSMutableDictionary new];_tickets=[NSMutableDictionary new];
        _progress=[NSProgress progressWithTotalUnitCount:files.count+2];
        _progress.localizedDescription=@"准备整合包";
        __weak HBRModpackTransaction *weak=self;
        _progress.cancellationHandler=^{HBRModpackTransaction *owner=weak;if (owner) dispatch_async(owner.queue,^{[owner abort:HBRCancelled()];});};
    }return self;
}
- (void)cancel { [self.progress cancel]; }
- (void)start { dispatch_async(self.queue,^{
    if (self.started) return;self.started=YES;
    if (self.progress.cancelled) { [self abort:HBRCancelled()];return; }
    NSError *error=nil;BOOL directory=NO;
    if (!self.destination.isFileURL || self.files.count>100000 || [NSFileManager.defaultManager fileExistsAtPath:self.destination.path isDirectory:&directory]) {
        [self abort:HBRImportError(@"实例目标已存在或无效，原有数据没有修改。")];return;
    }
    NSMutableSet *names=[NSMutableSet new];
    for (NSDictionary *file in self.files) {
        if (!HBRValidateModpackRemoteFile(file,&error)) { [self abort:error];return; }
        NSString *path=file[@"path"];
        NSString *normalized=[path.pathComponents componentsJoinedByString:@"/"].precomposedStringWithCanonicalMapping.lowercaseString;
        NSURL *target=[self.stage URLByAppendingPathComponent:path ?: @""];
        BOOL safe=normalized.length && !path.isAbsolutePath && ![path containsString:@"\\"] && ![path containsString:@":"];
        for (NSString *part in path.pathComponents) if ([part isEqual:@"."] || [part isEqual:@".."]) safe=NO;
        if (!safe || [names containsObject:normalized] || ![target.URLByStandardizingPath.path hasPrefix:[self.stage.path stringByAppendingString:@"/"]] || !HBRValidateModpackRemoteFile(file,&error)) {
            [self abort:error ?: HBRImportError(@"实例下载路径重复或无效。")];return;
        }
        [names addObject:normalized];
    }
    NSArray *sorted=[names.allObjects sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i=1;i<sorted.count;i++) if ([sorted[i] hasPrefix:[sorted[i-1] stringByAppendingString:@"/"]]) {
        [self abort:HBRImportError(@"下载路径把文件与文件夹混为同一路径。")];return;
    }
    [NSFileManager.defaultManager createDirectoryAtURL:self.stage.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
    if (!error && [NSFileManager.defaultManager createDirectoryAtURL:self.stage withIntermediateDirectories:NO attributes:nil error:&error]) self.ownsStage=YES;
    if (error) { [self abort:error];return; }
    [self pump];
});}
- (void)abort:(NSError *)error {
    if (self.ended) return;
    if (!self.failure) self.failure=error;
    for (HBRImportCancel cancel in self.active.allValues.copy) cancel();
    if (!self.active.count) [self finish];
}
- (void)pump {
    if (self.ended) return;
    if (self.progress.cancelled && !self.failure) self.failure=HBRCancelled();
    if (self.failure) { [self abort:self.failure];return; }
    while (self.active.count<3 && self.next<self.files.count) { NSUInteger index=self.next++;[self startFile:index]; }
    if (!self.active.count && self.finished==self.files.count) [self commitInstallation];
}
- (void)startFile:(NSUInteger)index {
    NSDictionary *file=self.files[index];NSNumber *key=@(index);
    NSUInteger attempt=[self.attempts[key] unsignedIntegerValue];NSArray *urls=file[@"downloads"];
    NSURL *target=[self.stage URLByAppendingPathComponent:file[@"path"]];
    self.progress.localizedDescription=[NSString stringWithFormat:@"下载并校验 %lu / %lu",(unsigned long)self.finished,(unsigned long)self.files.count];
    self.progress.localizedAdditionalDescription=file[@"path"];
    // Installing the placeholder before invoking a transport also covers a
    // synchronous cache hit; callbacks always re-enter the serial queue.
    self.active[key]=^{};
    NSUUID *ticket=NSUUID.UUID;self.tickets[key]=ticket;
    void (^done)(NSError *)=^(NSError *incomingError) {dispatch_async(self.queue,^{
        NSError *error=incomingError;
        if (!self.active[key] || ![self.tickets[key] isEqual:ticket]) return;
        [self.active removeObjectForKey:key];[self.tickets removeObjectForKey:key];
        if (!error && !self.failure && !self.progress.cancelled) {
            NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:target.path error:&error];
            if (!error && (![attributes[NSFileType] isEqual:NSFileTypeRegular] || ![attributes[NSFileSize] isEqual:file[@"fileSize"]])) error=HBRImportError(@"文件大小不匹配。");
            NSString *hash=!error ? HBRFileDigest(target.path,YES,&error):nil;
            if (!error && ![hash isEqualToString:[file[@"hashes"][@"sha512"] lowercaseString]]) error=HBRImportError(@"文件 SHA-512 校验失败。");
        }
        if (error && !self.failure && !self.progress.cancelled && attempt+1<urls.count) {
            [NSFileManager.defaultManager removeItemAtURL:target error:nil];self.attempts[key]=@(attempt+1);[self startFile:index];return;
        }
        if (error) [self abort:error];
        else if (self.progress.cancelled) [self abort:HBRCancelled()];
        else { self.finished++;self.progress.completedUnitCount=self.finished; }
        [self pump];
    });};
    HBRImportCancel cancel=nil;
    if (self.fetch) cancel=self.fetch(file,[NSURL URLWithString:urls[attempt]],target,done);
    else {
        HBRImportHTTP *transfer=[HBRImportHTTP new];transfer.target=target;transfer.expectedBytes=[file[@"fileSize"] unsignedLongLongValue];transfer.completion=done;
        [transfer start:[NSURL URLWithString:urls[attempt]]];cancel=^{[transfer.task cancel];};
    }
    self.active[key]=cancel ?: ^{};
}
- (void)commitInstallation {
    NSError *error=nil;
    if (self.progress.cancelled) { [self abort:HBRCancelled()];return; }
    self.progress.localizedDescription=@"应用整合包覆盖文件";
    if (!self.apply(self.stage,&error) || self.progress.cancelled) { [self abort:error ?: HBRCancelled()];return; }
    self.progress.completedUnitCount=self.files.count+1;
    if (![NSFileManager.defaultManager moveItemAtURL:self.stage toURL:self.destination error:&error]) { [self abort:error];return; }
    self.ownsStage=NO;self.ownsDestination=YES;
    __block BOOL saved=NO;__block NSError *saveError=nil;
    dispatch_sync(dispatch_get_main_queue(),^{
        if (!self.progress.cancelled) saved=self.commit(self.destination,&saveError);
    });
    if (!saved) { [self abort:saveError ?: HBRCancelled()];return; }
    self.ownsDestination=NO;
    self.progress.localizedDescription=@"整合包已导入";
    self.progress.completedUnitCount=self.progress.totalUnitCount;
    [self finish];
}
- (void)finish {
    if (self.ended) return;self.ended=YES;
    if (self.ownsStage) [NSFileManager.defaultManager removeItemAtURL:self.stage error:nil];
    if (self.ownsDestination) [NSFileManager.defaultManager removeItemAtURL:self.destination error:nil];
    self.progress.cancellationHandler=nil;
    void (^done)(NSError *)=self.completion;self.completion=nil;self.fetch=nil;self.apply=nil;self.commit=nil;
    dispatch_async(dispatch_get_main_queue(),^{if (done) done(self.failure);});
}
@end
