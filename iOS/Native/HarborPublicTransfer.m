#import "HarborPublicTransfer.h"
#import "HarborPublicDownloads.h"
#import "AFURLSessionManager.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <sys/stat.h>

// A whole game install resumes thousands of tasks. NSURLSession's idle timer
// also runs while a resumed task waits for a connection, so the short mirror
// timeout is only meaningful when the number of running transfers is bounded.
static const NSUInteger HBRTransferLimit=16;
static const long long HBRTransferMaximum=2LL*1024*1024*1024;
static char HBRTransferKey;
static NSUInteger HBRActiveTransfers;
static NSMutableArray *HBRWaitingTransfers(void) {
    static NSMutableArray *waiting;static dispatch_once_t once;
    dispatch_once(&once,^{waiting=[NSMutableArray new];});return waiting;
}
static NSError *HBRTransferError(NSString *message) { return [NSError errorWithDomain:@"net.morben.harbor.transfer" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }
static BOOL HBRTransferURLIsSafe(NSURL *url) { return [url.scheme.lowercaseString isEqual:@"https"] && url.host.length && !url.user && !url.password; }
// The game directory itself is reached through the engine's instance link, so
// only the final component is constrained: rename() replaces it, never follows it.
static BOOL HBRTransferTargetIsSafe(NSURL *destination) {
    if(!destination.isFileURL || !destination.path.isAbsolutePath)return NO;
    struct stat leaf;
    return lstat(destination.path.fileSystemRepresentation,&leaf)!=0 || S_ISREG(leaf.st_mode);
}

@interface HBRPublicTransfer : NSObject
@property AFURLSessionManager *manager;
@property NSArray<NSURL *> *urls;
@property NSURL *destination;
@property unsigned long long size;
@property NSString *sha1;
@property NSUInteger attempt;
@property NSURLSessionDownloadTask *first;
@property BOOL holdsSlot,waiting;
@property(copy) BOOL (^cancelled)(void);
@property(copy) void (^started)(NSURLSessionDownloadTask *,NSUInteger);
@property(copy) void (^progress)(NSProgress *);
@property(copy) void (^completion)(NSURLResponse *,NSURL *,NSError *);
- (NSURLSessionDownloadTask *)makeTask;
@end
@implementation HBRPublicTransfer
- (BOOL)isCancelled { BOOL (^cancelled)(void)=self.cancelled;return cancelled && cancelled(); }
- (NSError *)verify:(NSURL *)stage response:(NSURLResponse *)response {
    if (![response isKindOfClass:NSHTTPURLResponse.class] || ((NSHTTPURLResponse *)response).statusCode!=200) return HBRTransferError(@"下载来源未返回完整文件。");
    int descriptor=open(stage.path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);
    if(descriptor<0)return HBRTransferError(@"下载未生成可读取的临时文件。");
    NSFileHandle *input=[[NSFileHandle alloc] initWithFileDescriptor:descriptor closeOnDealloc:YES];
    struct stat info;
    // An empty file is only acceptable when its declared hash proves it.
    if(fstat(descriptor,&info)!=0 || !S_ISREG(info.st_mode) || info.st_size>HBRTransferMaximum || (info.st_size==0 && !self.sha1.length) || (self.size && (unsigned long long)info.st_size!=self.size)){[input closeFile];return HBRTransferError(@"下载大小不匹配或文件无效。");}
    CC_SHA1_CTX hash;CC_SHA1_Init(&hash);unsigned long long total=0;NSError *error=nil;NSData *first;
    for(;;){
        if(self.isCancelled){error=[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];break;}
        NSData *bytes=[input readDataUpToLength:65536 error:&error];if(error || !bytes.length)break;
        if(!first)first=bytes;total+=bytes.length;
        if(total>(unsigned long long)HBRTransferMaximum){error=HBRTransferError(@"下载文件超过 2 GB。");break;}
        CC_SHA1_Update(&hash,bytes.bytes,(CC_LONG)bytes.length);
    }
    [input closeFile];
    if(error)return error;
    if(total!=(unsigned long long)info.st_size)return HBRTransferError(@"校验时下载文件发生变化。");
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];CC_SHA1_Final(digest,&hash);
    if(self.sha1.length){
        NSMutableString *actual=[NSMutableString new];for(int i=0;i<CC_SHA1_DIGEST_LENGTH;i++)[actual appendFormat:@"%02x",digest[i]];
        if(![actual isEqual:self.sha1.lowercaseString])return HBRTransferError(@"下载 SHA-1 不匹配，尝试备用来源。");
    }
    if([self.destination.pathExtension.lowercaseString isEqual:@"jar"]){
        const unsigned char *bytes=first.bytes;
        if(first.length<4 || bytes[0]!='P' || bytes[1]!='K' || !((bytes[2]==3 && bytes[3]==4)||(bytes[2]==5 && bytes[3]==6)))return HBRTransferError(@"来源返回的不是有效 JAR / ZIP 文件。");
    }
    return nil;
}
- (NSError *)commit:(NSURL *)stage {
    if(!HBRTransferTargetIsSafe(self.destination))return HBRTransferError(@"下载目标是链接或目录，原文件保留。");
    NSString *path=self.destination.path;
    NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    NSError *error=nil;
    NSMutableDictionary *preserved=[@{NSFilePosixPermissions:attributes[NSFilePosixPermissions] ?: @0600} mutableCopy];
    #if TARGET_OS_IPHONE
    if(attributes[NSFileProtectionKey])preserved[NSFileProtectionKey]=attributes[NSFileProtectionKey];
    #endif
    if(![NSFileManager.defaultManager setAttributes:preserved ofItemAtPath:stage.path error:&error])return error ?: HBRTransferError(@"无法准备已校验的下载文件。");
    NSFileHandle *handle=[NSFileHandle fileHandleForWritingToURL:stage error:&error];
    if(!handle)return error ?: HBRTransferError(@"无法准备已校验的下载文件。");
    BOOL synced=[handle synchronizeAndReturnError:&error];[handle closeFile];
    if(!synced)return error ?: HBRTransferError(@"无法写入已校验的下载文件。");
    if(rename(stage.path.fileSystemRepresentation,path.fileSystemRepresentation)!=0)return HBRTransferError(@"无法提交已校验的下载文件，原文件保留。");
    return nil;
}
- (void)releaseSlot {
    HBRPublicTransfer *next=nil;NSURLSessionDownloadTask *first=nil;
    @synchronized(HBRPublicTransfer.class){
        first=self.first;self.first=nil;
        if(self.waiting){self.waiting=NO;[HBRWaitingTransfers() removeObjectIdenticalTo:self];}
        if(self.holdsSlot){
            self.holdsSlot=NO;
            if(HBRWaitingTransfers().count){next=HBRWaitingTransfers().firstObject;[HBRWaitingTransfers() removeObjectAtIndex:0];next.waiting=NO;next.holdsSlot=YES;}
            else HBRActiveTransfers--;
        }
    }
    if(first)objc_setAssociatedObject(first,&HBRTransferKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [next.first resume];
}
- (void)finish:(NSURLResponse *)response file:(NSURL *)file error:(NSError *)error {
    void (^completion)(NSURLResponse *,NSURL *,NSError *)=self.completion;self.completion=nil;self.started=nil;self.progress=nil;self.cancelled=nil;
    [self releaseSlot];
    if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(response,file,error);});
}
- (NSURLSessionDownloadTask *)makeTask {
    if(self.attempt>=self.urls.count || self.isCancelled)return nil;
    NSURL *source=self.urls[self.attempt++];
    NSURL *stage=[self.destination.URLByDeletingLastPathComponent URLByAppendingPathComponent:[@".harbor-download-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:source cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25];
    request.HTTPShouldHandleCookies=NO;[request setValue:@"MC-Harbor-iOS/0.1" forHTTPHeaderField:@"User-Agent"];
    __block NSError *failure=nil;NSObject *gate=[NSObject new];
    NSURLSessionDownloadTask *task=[self.manager downloadTaskWithRequest:request progress:^(NSProgress *progress){
        if(progress.completedUnitCount>HBRTransferMaximum || (self.size && (unsigned long long)progress.completedUnitCount>self.size)){@synchronized(gate){failure=HBRTransferError(@"下载数据超过声明大小。");}[progress cancel];}
        void (^progressBlock)(NSProgress *)=self.progress;if(progressBlock)progressBlock(progress);
    } destination:^NSURL *(NSURL *temporary,NSURLResponse *response){
        NSError *error=nil;[NSFileManager.defaultManager createDirectoryAtURL:stage.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];if(error)@synchronized(gate){failure=error;}return stage;
    } completionHandler:^(NSURLResponse *response,NSURL *file,NSError *error){
        // AF completion defaults to main. Large file hashing and fsync belong
        // on the utility queue; only UI completion/progress bookkeeping return.
        NSError *resultError=error;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            NSError *error=resultError;@synchronized(gate){error=failure ?: error;}
            if(self.isCancelled)error=[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            if(!error)error=[self verify:stage response:response];
            if(!error)error=[self commit:stage];
            [NSFileManager.defaultManager removeItemAtURL:stage error:nil];
            BOOL stopped=[error.domain isEqualToString:NSURLErrorDomain] && error.code==NSURLErrorCancelled;
            if(error && !stopped && self.attempt<self.urls.count && !self.isCancelled){
                dispatch_async(dispatch_get_main_queue(),^{NSURLSessionDownloadTask *retry=[self makeTask];if(retry)[retry resume];else [self finish:response file:nil error:error];});return;
            }
            [self finish:response file:error ? nil:self.destination error:error];
        });
    }];
    // The first call runs on the caller's thread, retries on the main queue.
    void (^started)(NSURLSessionDownloadTask *,NSUInteger)=self.started;
    if(started && task)started(task,self.attempt);
    return task;
}
@end

NSURLSessionDownloadTask *HBRCreatePublicTransfer(AFURLSessionManager *manager,NSURL *source,NSURL *destination,unsigned long long size,NSString *sha1,BOOL (^cancelled)(void),void (^started)(NSURLSessionDownloadTask *,NSUInteger),void (^progress)(NSProgress *),void (^completion)(NSURLResponse *,NSURL *,NSError *)) {
    NSArray<NSURL *> *urls=HBRPublicDownloadURLs(source,HBRPublicDownloadRoute());
    BOOL valid=manager && urls.count>0 && destination && HBRTransferTargetIsSafe(destination);
    for(NSURL *url in urls)valid=valid && HBRTransferURLIsSafe(url) && (!url.port || url.port.integerValue==443);
    if(!valid){dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(nil,nil,HBRTransferError(@"公共下载地址或目标路径无效，原文件保留。"));});return nil;}
    // Mirrors hand files to cache nodes on arbitrary HTTPS ports. The redirect
    // target never receives cookies or request headers.
    [manager setTaskWillPerformHTTPRedirectionBlock:^NSURLRequest *(NSURLSession *session,NSURLSessionTask *task,NSURLResponse *response,NSURLRequest *request){
        if(!HBRTransferURLIsSafe(request.URL))return nil;
        // A new request: assigning allHTTPHeaderFields keeps headers it does not name.
        NSMutableURLRequest *safe=[NSMutableURLRequest requestWithURL:request.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25];
        safe.HTTPShouldHandleCookies=NO;[safe setValue:@"MC-Harbor-iOS/0.1" forHTTPHeaderField:@"User-Agent"];return safe;
    }];
    HBRPublicTransfer *transfer=[HBRPublicTransfer new];transfer.manager=manager;transfer.urls=urls;transfer.destination=destination;transfer.size=size;transfer.sha1=sha1;transfer.cancelled=cancelled;transfer.started=started;transfer.progress=progress;transfer.completion=completion;
    NSURLSessionDownloadTask *task=[transfer makeTask];
    if(task){transfer.first=task;objc_setAssociatedObject(task,&HBRTransferKey,transfer,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    else dispatch_async(dispatch_get_main_queue(),^{[transfer finish:nil file:nil error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];});
    return task;
}

void HBRStartPublicTransfer(NSURLSessionDownloadTask *task) {
    if(!task)return;
    HBRPublicTransfer *transfer=objc_getAssociatedObject(task,&HBRTransferKey);
    BOOL run=!transfer;
    if(transfer)@synchronized(HBRPublicTransfer.class){
        if(transfer.holdsSlot || transfer.waiting || !transfer.first)return;
        if(HBRActiveTransfers<HBRTransferLimit){HBRActiveTransfers++;transfer.holdsSlot=YES;run=YES;}
        else{transfer.waiting=YES;[HBRWaitingTransfers() addObject:transfer];}
    }
    if(run)[task resume];
}
