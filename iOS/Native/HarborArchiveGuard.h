#import <Foundation/Foundation.h>
@class UZKArchive;
BOOL HBRValidateArchive(UZKArchive *archive, NSString *destination, NSError **error);
BOOL HBRValidateRemoteFiles(NSArray *files, NSString *destination, NSError **error);
BOOL HBRValidateDestination(NSString *relative, NSString *destination, NSError **error);
void HBRExtractDirectory(UZKArchive *archive, NSString *directory, NSString *destination, NSError **error);
