#import <Foundation/Foundation.h>
#import "HarborModpackTransaction.h"
#import "HarborModpackMetadata.h"

static NSUInteger checks;
#define CHECK(x) do { checks++;if (!(x)) {NSLog(@"FAIL %d: %s",__LINE__,#x);exit(1);} } while(0)
static BOOL done;
static NSError *result;
static NSString *root;
static NSData *payload;
static NSDictionary *base;
static NSError *problem(void) {return [NSError errorWithDomain:@"fixture" code:1 userInfo:nil];}
static NSDictionary *file(NSString *path) {NSMutableDictionary *f=base.mutableCopy;f[@"path"]=path;return f;}
static NSURL *destination(void) {return [NSURL fileURLWithPath:[root stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];}
static HBRModpackTransaction *operation(NSURL *dest,NSArray *files,HBRImportStageAction apply,HBRImportStageAction commit) {
    done=NO;result=nil;
    return [[HBRModpackTransaction alloc] initWithDestination:dest files:files applyOverrides:apply commit:commit completion:^(NSError *error){CHECK(!done);result=error;done=YES;}];
}
static void waitForCompletion(void) {
    NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:5];
    while (!done && limit.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(done);
}
static void cleanStage(void) {
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) CHECK(![name hasPrefix:@".import-"]);
}
static HBRImportFetch transport(NSMutableArray *calls,BOOL fail,BOOL corrupt,BOOL synchronous) {
    return ^HBRImportCancel(NSDictionary *f,NSURL *url,NSURL *target,void (^completion)(NSError *)) {
        @synchronized(calls) {[calls addObject:url.absoluteString];}
        NSObject *lock=[NSObject new];__block BOOL terminal=NO;
        void (^perform)(void)=^{ @synchronized(lock) {
            if (terminal) return;terminal=YES;
            if (fail || [url.path hasSuffix:@"first-error"]) {completion(problem());return;}
            NSData *bytes=(corrupt || [url.path hasSuffix:@"first-corrupt"]) ? [@"not the correct payload" dataUsingEncoding:NSUTF8StringEncoding]:payload;
            NSError *error=nil;[NSFileManager.defaultManager createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
            if (!error) [bytes writeToURL:target options:NSDataWritingAtomic error:&error];completion(error);
        }};
        if (synchronous) perform();else dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.06*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),perform);
        return ^{ @synchronized(lock) {if (terminal) return;terminal=YES;completion([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);}};
    };
}
int main(void) { @autoreleasepool {
    root=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"harbor-txn-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    @try {
        payload=[@"actual downloaded fixture payload" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *original=[root stringByAppendingPathComponent:@"original.mrpack"];
        [payload writeToFile:original atomically:YES];
        base=@{@"path":@"mods/a.jar",@"fileSize":@(payload.length),@"downloads":@[@"https://cdn.modrinth.com/a"],
               @"hashes":@{@"sha1":HBRFileDigest(original,NO,nil),@"sha512":HBRFileDigest(original,YES,nil)}};
        HBRImportStageAction noOp=^BOOL(NSURL *directory,NSError **error){return YES;};
        NSMutableArray *calls=[NSMutableArray new];NSURL *dest=destination();__block NSUInteger commits=0;
        HBRModpackTransaction *op=operation(dest,@[file(@"mods/a.jar"),file(@"mods/b.jar"),file(@"config/c.json")],^BOOL(NSURL *stage,NSError **error){
            CHECK(calls.count==3);CHECK(![NSFileManager.defaultManager fileExistsAtPath:dest.path]);
            for (NSString *path in @[@"mods/a.jar",@"mods/b.jar",@"config/c.json"]) CHECK([[NSData dataWithContentsOfURL:[stage URLByAppendingPathComponent:path]] isEqual:payload]);
            return [[@"override wins" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:[stage URLByAppendingPathComponent:@"mods/a.jar"] options:NSDataWritingAtomic error:error];
        },^BOOL(NSURL *directory,NSError **error){
            CHECK(NSThread.isMainThread);commits++;CHECK([directory isEqual:dest]);
            CHECK([[NSString stringWithContentsOfURL:[directory URLByAppendingPathComponent:@"mods/a.jar"] encoding:NSUTF8StringEncoding error:nil] isEqual:@"override wins"]);return YES;
        });op.fetch=transport(calls,NO,NO,NO);[op start];[op start];waitForCompletion();
        CHECK(!result);CHECK(commits==1);CHECK(op.progress.completedUnitCount==op.progress.totalUnitCount);cleanStage();
        CHECK([[NSData dataWithContentsOfFile:original] isEqual:payload]);

        // A failed first source or corrupt first payload must use the next URL.
        for (NSString *suffix in @[@"first-error",@"first-corrupt"]) {
            NSMutableDictionary *f=file(@"mods/fallback.jar").mutableCopy;
            f[@"downloads"]=@[[@"https://cdn.modrinth.com/" stringByAppendingString:suffix],@"https://github.com/success"];
            calls=[NSMutableArray new];dest=destination();op=operation(dest,@[f],noOp,noOp);op.fetch=transport(calls,NO,NO,NO);
            [op start];waitForCompletion();CHECK(!result);CHECK(calls.count==2);CHECK([[NSData dataWithContentsOfURL:[dest URLByAppendingPathComponent:f[@"path"]]] isEqual:payload]);cleanStage();
        }
        // A cache hit may complete synchronously, even for an empty pack.
        // A delayed duplicate callback from an old source cannot consume the
        // newly started fallback attempt's active slot or commit incomplete data.
        NSMutableDictionary *duplicate=file(@"mods/duplicate.jar").mutableCopy;
        duplicate[@"downloads"]=@[@"https://cdn.modrinth.com/first-error",@"https://cdn.modrinth.com/success"];
        dest=destination();calls=[NSMutableArray new];op=operation(dest,@[duplicate],noOp,noOp);
        HBRImportFetch regular=transport(calls,NO,NO,NO);
        op.fetch=^HBRImportCancel(NSDictionary *f,NSURL *url,NSURL *target,void (^completion)(NSError *)) {
            if ([url.path hasSuffix:@"first-error"]) {completion(problem());completion(problem());return ^{};}
            return regular(f,url,target,completion);
        };
        [op start];waitForCompletion();CHECK(!result);CHECK(calls.count==1);cleanStage();
        for (NSArray *files in @[@[file(@"mods/cached.jar")],@[]]) {
            calls=[NSMutableArray new];dest=destination();op=operation(dest,files,noOp,noOp);op.fetch=transport(calls,NO,NO,YES);
            [op start];waitForCompletion();CHECK(!result);CHECK(calls.count==files.count);cleanStage();
        }
        // Failure and cancellation never expose a partially installed instance.
        for (NSUInteger scenario=0;scenario<5;scenario++) {
            dest=destination();calls=[NSMutableArray new];__block BOOL saved=NO;
            HBRImportStageAction apply=scenario==2 ? ^BOOL(NSURL *stage,NSError **error){*error=problem();return NO;}:noOp;
            op=operation(dest,@[file(@"mods/fail.jar")],apply,^BOOL(NSURL *directory,NSError **error){saved=YES;if (scenario==3) {*error=problem();return NO;}return YES;});
            op.fetch=transport(calls,scenario==0,scenario==1,NO);
            if (scenario==4) [op cancel];[op start];waitForCompletion();CHECK(result!=nil);CHECK(saved==(scenario==3));CHECK(![NSFileManager.defaultManager fileExistsAtPath:dest.path]);cleanStage();
        }
        // Cancel active requests. Their completion callbacks settle before cleanup.
        dest=destination();calls=[NSMutableArray new];op=operation(dest,@[file(@"1.jar"),file(@"2.jar"),file(@"3.jar"),file(@"4.jar")],noOp,^BOOL(NSURL *directory,NSError **error){CHECK(NO);return YES;});
        op.fetch=transport(calls,NO,NO,NO);[op start];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.01*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[op cancel];});
        waitForCompletion();CHECK(result.code==NSURLErrorCancelled);CHECK(calls.count<=3);CHECK(![NSFileManager.defaultManager fileExistsAtPath:dest.path]);cleanStage();

        // The native task button cancels the parent progress, not this object.
        // Verify actual Foundation child propagation and settled cleanup.
        dest=destination();calls=[NSMutableArray new];
        op=operation(dest,@[file(@"mods/parent-cancel.jar")],noOp,^BOOL(NSURL *directory,NSError **error){CHECK(NO);return YES;});
        op.fetch=transport(calls,NO,NO,NO);
        NSProgress *parent=[NSProgress progressWithTotalUnitCount:op.progress.totalUnitCount];
        [parent addChild:op.progress withPendingUnitCount:op.progress.totalUnitCount];[op start];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.01*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[parent cancel];});
        waitForCompletion();CHECK(op.progress.cancelled);CHECK(result.code==NSURLErrorCancelled);
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:dest.path]);cleanStage();

        // Existing destinations and invalid plans remain untouched.
        dest=destination();[NSFileManager.defaultManager createDirectoryAtURL:dest withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *world=[dest URLByAppendingPathComponent:@"world.dat"];[payload writeToURL:world atomically:YES];
        calls=[NSMutableArray new];op=operation(dest,@[file(@"mods/new.jar")],noOp,noOp);op.fetch=transport(calls,NO,NO,YES);[op start];waitForCompletion();
        CHECK(result);CHECK(!calls.count);CHECK([[NSData dataWithContentsOfURL:world] isEqual:payload]);
        for (NSArray *files in @[@[file(@"../outside")],@[file(@"/absolute")],@[file(@"a"),file(@"a/b")],@[file(@"MODS/a.jar"),file(@"mods/a.jar")]]) {
            dest=destination();calls=[NSMutableArray new];op=operation(dest,files,noOp,noOp);op.fetch=transport(calls,NO,NO,YES);[op start];waitForCompletion();CHECK(result);CHECK(!calls.count);CHECK(![NSFileManager.defaultManager fileExistsAtPath:dest.path]);cleanStage();
        }
        CHECK([[NSData dataWithContentsOfFile:original] isEqual:payload]);
        NSLog(@"HARBOR_IMPORT_TRANSACTION_PASS %lu checks",(unsigned long)checks);
    } @finally { [NSFileManager.defaultManager removeItemAtPath:root error:nil]; }
}return 0;}
