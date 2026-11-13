#import <Foundation/Foundation.h>

// Input is untrusted modpack metadata. Storage names never use the pack title.
FOUNDATION_EXPORT NSDictionary *HBRResolveModpackDependencies(id dependencies, NSString *versionsDirectory, NSError **error);
FOUNDATION_EXPORT BOOL HBRValidateModpackName(id name, NSError **error);
FOUNDATION_EXPORT NSString *HBRUniqueModpackName(NSString *name, NSDictionary *profiles);
FOUNDATION_EXPORT NSString *HBRNewModpackStorageName(void);
FOUNDATION_EXPORT BOOL HBRValidateModpackRemoteFile(id file, NSError **error);
FOUNDATION_EXPORT BOOL HBRModpackFileSupportsClient(NSDictionary *file);
FOUNDATION_EXPORT NSDictionary *HBRParseModpackIndex(id data, NSError **error);
FOUNDATION_EXPORT NSString *HBRFileDigest(NSString *path, BOOL sha512, NSError **error);
