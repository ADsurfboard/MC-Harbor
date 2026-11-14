#import <Foundation/Foundation.h>
#import "HarborModpackTransaction.h"

// This runs the production NSURLSession transport against a public CDN file,
// with no injected fetch block and no player profiles, worlds or credentials.
int main(int argc,const char **argv) { @autoreleasepool {
    if (argc!=3) return 2;
    NSError *error=nil;
    NSData *data=[NSData dataWithContentsOfFile:@(argv[1]) options:0 error:&error];
    NSDictionary *file=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error]:nil;
    if (!file || error) return 3;
    __block BOOL done=NO,committed=NO;__block NSError *failure=nil;
    NSURL *destination=[NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
    HBRModpackTransaction *transaction=[[HBRModpackTransaction alloc] initWithDestination:destination files:@[file]
        applyOverrides:^BOOL(NSURL *stage,NSError **problem){return YES;}
        commit:^BOOL(NSURL *directory,NSError **problem){committed=YES;return YES;}
        completion:^(NSError *problem){failure=problem;done=YES;}];
    [transaction start];
    NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:120];
    while (!done && limit.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    if (!done) {
        [transaction cancel];NSDate *settle=[NSDate dateWithTimeIntervalSinceNow:5];
        while (!done && settle.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    if (!done || failure || !committed || transaction.progress.completedUnitCount!=transaction.progress.totalUnitCount) {
        NSLog(@"HARBOR_IMPORT_NETWORK_FAIL %@",failure.localizedDescription ?: @"timeout");return 1;
    }
    NSLog(@"HARBOR_IMPORT_NETWORK_PASS real HTTPS, streamed SHA-512, committed once");return 0;
} }
