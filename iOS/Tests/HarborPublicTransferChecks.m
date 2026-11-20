#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "AFURLSessionManager.h"
#import "HarborPublicTransfer.h"

static NSUInteger checks;
static void Check(BOOL okay,NSString *message) { checks++;if(!okay){NSLog(@"FAILED: %@",message);exit(1);} }
static NSLock *lock;
static NSMutableArray<NSURLRequest *> *requests;
static NSInteger running,peak;
static NSString *const Mirror=@"bmclapi2.bangbang93.com";

static NSData *Payload(NSString *name) {
    if([name containsString:@"empty"])return [NSData data];
    if([name containsString:@"zip"])return [@"PK\x03\x04 archive " stringByAppendingString:name].UTF8String ? [[@"PK\x03\x04 archive " stringByAppendingString:name] dataUsingEncoding:NSUTF8StringEncoding]:nil;
    return [[@"payload-" stringByAppendingString:name] dataUsingEncoding:NSUTF8StringEncoding];
}
static NSString *SHA1(NSData *data) {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];CC_SHA1(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *text=[NSMutableString new];for(int i=0;i<CC_SHA1_DIGEST_LENGTH;i++)[text appendFormat:@"%02x",digest[i]];return text;
}

@interface TransferFixtureProtocol : NSURLProtocol @end
@implementation TransferFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)stopLoading {}
- (void)respond:(NSInteger)status body:(NSData *)body {
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Length":@(body.length).stringValue}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:body];[self.client URLProtocolDidFinishLoading:self];
}
- (void)startLoading {
    NSURL *url=self.request.URL;NSString *name=url.lastPathComponent;BOOL mirror=[url.host isEqual:Mirror];
    [lock lock];[requests addObject:self.request];[lock unlock];
    if(mirror && [name containsString:@"mtimeout"]){[self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]];return;}
    if(mirror && ([name containsString:@"redirect"] || [name containsString:@"insecure"])){
        NSString *target=[name containsString:@"insecure"] ? @"http://node.example/":@"https://node.example:8443/";
        NSURL *next=[NSURL URLWithString:[target stringByAppendingString:name]];
        NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:url statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Location":next.absoluteString}];
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:next];[request setValue:@"secret=1" forHTTPHeaderField:@"Cookie"];
        [self.client URLProtocol:self wasRedirectedToRequest:request redirectResponse:response];
        // A refused redirect ends a real HTTP load with the 302 itself.
        if([name containsString:@"insecure"])[self respond:302 body:[NSData data]];
        return;
    }
    if([name containsString:@"allfail"] || (mirror && [name containsString:@"m503"])){[self respond:503 body:[@"unavailable" dataUsingEncoding:NSUTF8StringEncoding]];return;}
    NSData *body=mirror && [name containsString:@"mbad"] ? [@"tampered mirror copy" dataUsingEncoding:NSUTF8StringEncoding]:Payload(name);
    if(![name containsString:@"slow"]){[self respond:200 body:body];return;}
    [lock lock];running++;peak=MAX(peak,running);[lock unlock];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        [lock lock];running--;[lock unlock];[self respond:200 body:body];
    });
}
@end

static AFURLSessionManager *manager;
static NSURL *root;
static void Wait(BOOL (^done)(void),NSString *message) {
    NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:20];
    while(!done() && limit.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(done(),[@"Timed out: " stringByAppendingString:message]);
}
static NSArray<NSString *> *Hosts(NSString *name) {
    NSMutableArray *hosts=[NSMutableArray new];[lock lock];
    for(NSURLRequest *request in requests)if([request.URL.lastPathComponent isEqual:name])[hosts addObject:request.URL.host];
    [lock unlock];return hosts;
}
/// Runs one transfer to completion and returns its error; attempts receives every started() call.
static NSError *Run(NSString *name,NSURL *destination,unsigned long long size,NSString *sha1,NSMutableArray *attempts,BOOL bounded) {
    __block NSUInteger completions=0;__block NSError *result=nil;__block NSURL *reported=nil;
    NSURL *source=[NSURL URLWithString:[@"https://piston-data.mojang.com/v1/objects/" stringByAppendingString:name]];
    NSURLSessionDownloadTask *task=HBRCreatePublicTransfer(manager,source,destination,size,sha1,nil,^(NSURLSessionDownloadTask *started,NSUInteger attempt){
        Check(started.state==NSURLSessionTaskStateSuspended,@"started must receive a real suspended task");[attempts addObject:@(attempt)];
    },nil,^(NSURLResponse *response,NSURL *file,NSError *error){
        Check(NSThread.isMainThread,@"completion must run on the main thread");completions++;result=error;reported=file;
    });
    if(bounded)HBRStartPublicTransfer(task);else [task resume];
    Wait(^BOOL{return completions>0;},name);
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    Check(completions==1,[name stringByAppendingString:@": completion exactly once"]);
    Check((result==nil)==(reported!=nil),[name stringByAppendingString:@": file is reported only on success"]);
    for(NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:destination.URLByDeletingLastPathComponent.path error:nil])
        Check(![entry hasPrefix:@".harbor-download-"],[name stringByAppendingString:@": no staging file may remain"]);
    return result;
}

int main(void) { @autoreleasepool {
    lock=[NSLock new];requests=[NSMutableArray new];
    root=[[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[@"harbor-transfer-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSFileManager *files=NSFileManager.defaultManager;
    Check([files createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil],@"fixture directory");
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses=@[TransferFixtureProtocol.class];
    manager=[[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    NSData *old=[@"previous verified file" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *(^target)(NSString *)=^NSURL *(NSString *name){return [root URLByAppendingPathComponent:name];};
    NSMutableArray *attempts;NSError *error;NSString *name;

    // Domestic mirror first, verified by the declared size and SHA-1.
    name=@"plain.bin";attempts=[NSMutableArray new];
    error=Run(name,target(@"nested/dir/plain.bin"),Payload(name).length,SHA1(Payload(name)),attempts,YES);
    Check(!error && [[NSData dataWithContentsOfURL:target(@"nested/dir/plain.bin")] isEqual:Payload(name)],@"mirror download is committed");
    Check([attempts isEqual:@[@1]] && [Hosts(name) isEqual:@[Mirror]],@"a healthy mirror needs one attempt");

    // Modrinth supplies SHA-512; reject a bad mirror before renaming it.
    name=@"mbad-sha512.bin";attempts=[NSMutableArray new];
    NSData *original=Payload(name);
    unsigned char digest[CC_SHA512_DIGEST_LENGTH];
    CC_SHA512(original.bytes,(CC_LONG)original.length,digest);
    NSMutableString *checksum=[NSMutableString stringWithString:@"sha512:"];
    for(NSUInteger i=0;i<sizeof(digest);i++) [checksum appendFormat:@"%02x",digest[i]];
    [old writeToURL:target(name) atomically:YES];
    error=Run(name,target(name),0,checksum,attempts,YES);
    Check(!error && attempts.count==2 && [[NSData dataWithContentsOfURL:target(name)] isEqual:original],
          @"a corrupt mirror cannot replace a SHA-512 verified file");

    // Mirror timeout, HTTP error and tampered bytes each fall back to the official source.
    for(name in @[@"mtimeout.bin",@"m503.bin",@"mbad.bin"]){
        attempts=[NSMutableArray new];[old writeToURL:target(name) atomically:YES];
        error=Run(name,target(name),0,SHA1(Payload(name)),attempts,[name hasPrefix:@"m5"]);
        Check(!error && [[NSData dataWithContentsOfURL:target(name)] isEqual:Payload(name)],[name stringByAppendingString:@": official copy replaces the old file"]);
        Check([attempts isEqual:@[@1,@2]],[name stringByAppendingString:@": started is called for the retry"]);
        Check(([Hosts(name) isEqual:@[Mirror,@"piston-data.mojang.com"]]),[name stringByAppendingString:@": mirror then official"]);
    }

    // Total failure keeps the player's existing file byte-for-byte.
    for(name in @[@"allfail.bin",@"wrongsize.bin",@"wronghash.bin",@"notarchive.jar",@"empty-unverified.bin"]){
        [old writeToURL:target(name) atomically:YES];attempts=[NSMutableArray new];
        NSString *sha=[name hasPrefix:@"wronghash"] ? SHA1(old):nil;
        error=Run(name,target(name),[name hasPrefix:@"wrongsize"] ? 3:0,sha,attempts,NO);
        Check(error && [[NSData dataWithContentsOfURL:target(name)] isEqual:old],[name stringByAppendingString:@": failure preserves the old file"]);
        Check(attempts.count==2,[name stringByAppendingString:@": both sources are tried before failing"]);
    }

    // Archives and hash-proven empty files are accepted.
    name=@"zip-library.jar";error=Run(name,target(name),0,nil,[NSMutableArray new],YES);
    Check(!error && [[NSData dataWithContentsOfURL:target(name)] isEqual:Payload(name)],@"a real archive header is accepted");
    name=@"empty-proven.bin";error=Run(name,target(name),0,@"da39a3ee5e6b4b0d3255bfef95601890afd80709",[NSMutableArray new],YES);
    Check(!error && [files fileExistsAtPath:target(name).path] && [NSData dataWithContentsOfURL:target(name)].length==0,@"an empty file proven by its hash is accepted");

    // Mirror cache nodes on other HTTPS ports are followed without cookies; plain HTTP is refused.
    name=@"redirect.bin";attempts=[NSMutableArray new];error=Run(name,target(name),0,SHA1(Payload(name)),attempts,YES);
    Check(!error && [attempts isEqual:@[@1]] && ([Hosts(name) isEqual:@[Mirror,@"node.example"]]),@"HTTPS cache-node redirect is followed");
    [lock lock];for(NSURLRequest *request in requests){
        Check(![request valueForHTTPHeaderField:@"Cookie"] && ![request valueForHTTPHeaderField:@"Authorization"],@"no credentials reach any source");
        Check([request.URL.scheme isEqual:@"https"],@"only HTTPS requests are sent");
    }[lock unlock];
    name=@"insecure.bin";attempts=[NSMutableArray new];error=Run(name,target(name),0,SHA1(Payload(name)),attempts,YES);
    Check(!error && [attempts isEqual:@[@1,@2]] && ([Hosts(name) isEqual:@[Mirror,@"piston-data.mojang.com"]]),@"HTTP redirect is refused and the official source is used");

    // The engine's game directory is itself a link; only a linked final component is refused.
    NSURL *real=target(@"instances/default"),*link=target(@"minecraft");
    [files createDirectoryAtURL:real withIntermediateDirectories:YES attributes:nil error:nil];
    Check([files createSymbolicLinkAtURL:link withDestinationURL:real error:nil],@"instance link fixture");
    name=@"linked-parent.bin";error=Run(name,[link URLByAppendingPathComponent:@"libraries/a/linked-parent.bin"],0,SHA1(Payload(name)),[NSMutableArray new],YES);
    Check(!error && [[NSData dataWithContentsOfURL:[real URLByAppendingPathComponent:@"libraries/a/linked-parent.bin"]] isEqual:Payload(name)],@"downloads work through the instance link");
    [old writeToURL:target(@"outside.bin") atomically:YES];
    Check([files createSymbolicLinkAtURL:target(@"leaf-link.bin") withDestinationURL:target(@"outside.bin") error:nil],@"leaf link fixture");
    name=@"leaf-link.bin";attempts=[NSMutableArray new];error=Run(name,target(name),0,nil,attempts,YES);
    Check(error && attempts.count==0 && Hosts(name).count==0,@"a linked destination is refused before any request");
    Check([[NSData dataWithContentsOfURL:target(@"outside.bin")] isEqual:old],@"the link target is untouched");

    // Invalid sources never start; cancellation never falls back.
    __block NSError *invalid=nil;
    Check(!HBRCreatePublicTransfer(manager,[NSURL URLWithString:@"http://example.com/a.bin"],target(@"http.bin"),0,nil,nil,nil,nil,^(NSURLResponse *r,NSURL *f,NSError *e){invalid=e;}),@"plain HTTP source is refused");
    Wait(^BOOL{return invalid!=nil;},@"invalid source completion");
    __block NSError *stopped=nil;__block BOOL cancelled=NO;
    NSURLSessionDownloadTask *task=HBRCreatePublicTransfer(manager,[NSURL URLWithString:@"https://piston-data.mojang.com/v1/objects/m503-cancel.bin"],target(@"cancel.bin"),0,nil,^BOOL{return cancelled;},nil,nil,^(NSURLResponse *r,NSURL *f,NSError *e){stopped=e;});
    cancelled=YES;HBRStartPublicTransfer(task);
    Wait(^BOOL{return stopped!=nil;},@"cancelled completion");
    Check(stopped.code==NSURLErrorCancelled && Hosts(@"m503-cancel.bin").count==1 && ![files fileExistsAtPath:target(@"cancel.bin").path],@"a cancelled install does not retry or write");

    // A full install queues every file; only a bounded number may hold a connection.
    __block NSUInteger finished=0,failed=0;NSUInteger total=60;
    NSMutableArray *tasks=[NSMutableArray new];
    for(NSUInteger i=0;i<total;i++){
        NSString *file=[NSString stringWithFormat:@"slow-%lu.bin",(unsigned long)i];
        NSURLSessionDownloadTask *queued=HBRCreatePublicTransfer(manager,[NSURL URLWithString:[@"https://resources.download.minecraft.net/ab/" stringByAppendingString:file]],target([@"assets/" stringByAppendingString:file]),0,SHA1(Payload(file)),nil,nil,nil,^(NSURLResponse *r,NSURL *f,NSError *e){finished++;if(e)failed++;});
        Check(queued!=nil,@"queued transfer is created");[tasks addObject:queued];
    }
    for(NSURLSessionDownloadTask *queued in tasks){HBRStartPublicTransfer(queued);HBRStartPublicTransfer(queued);}
    Wait(^BOOL{return finished==total;},@"queued transfers");
    Check(failed==0 && [files contentsOfDirectoryAtPath:target(@"assets").path error:nil].count==total,@"every queued file is committed once");
    [lock lock];NSInteger most=peak;[lock unlock];
    Check(most>1 && most<=16,[NSString stringWithFormat:@"running transfers stay bounded (peak %ld)",(long)most]);
    name=@"after-queue.bin";error=Run(name,target(name),0,SHA1(Payload(name)),[NSMutableArray new],YES);
    Check(!error,@"the queue releases its slots after a batch");

    [manager invalidateSessionCancelingTasks:YES resetSession:NO];
    [files removeItemAtURL:root error:nil];
    printf("PASS: %lu real AFNetworking / NSURLSession transfer checks; no network, player data, preferences or credentials used.\n",(unsigned long)checks);
    return 0;
}}
