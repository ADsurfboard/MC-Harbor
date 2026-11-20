#import <Foundation/Foundation.h>
@class AFURLSessionManager;

/// Returns the first real, suspended download task. Retries create/resume real
/// tasks and call started again, so callers can retain accurate progress.
/// The destination keeps its previous contents until a source is verified.
NSURLSessionDownloadTask *HBRCreatePublicTransfer(AFURLSessionManager *manager,NSURL *source,NSURL *destination,
    unsigned long long expectedSize,NSString *checksum,BOOL (^cancelled)(void),
    void (^started)(NSURLSessionDownloadTask *,NSUInteger),void (^progress)(NSProgress *),
    void (^completion)(NSURLResponse *,NSURL *,NSError *));

/// Resumes a transfer through a bounded queue, so the short idle timeout
/// measures a live connection instead of time spent waiting for one.
void HBRStartPublicTransfer(NSURLSessionDownloadTask *task);
