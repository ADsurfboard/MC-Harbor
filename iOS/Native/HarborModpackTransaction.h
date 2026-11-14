#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^HBRImportCancel)(void);
// A transport must call completion once, including after cancellation. All
// writes belong to the supplied private staging target, never a live instance.
typedef HBRImportCancel _Nullable (^HBRImportFetch)(NSDictionary *file, NSURL *url, NSURL *target, void (^completion)(NSError *_Nullable));
typedef BOOL (^HBRImportStageAction)(NSURL *directory, NSError **error);

@interface HBRModpackTransaction : NSObject
@property(nonatomic,readonly) NSProgress *progress;
@property(nonatomic,copy,nullable) HBRImportFetch fetch;
- (instancetype)initWithDestination:(NSURL *)destination files:(NSArray<NSDictionary *> *)files
                    applyOverrides:(HBRImportStageAction)apply commit:(HBRImportStageAction)commit
                        completion:(void (^)(NSError *_Nullable))completion;
- (void)start;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
