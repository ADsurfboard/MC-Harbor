#import <Foundation/Foundation.h>
// A nil entry returns a JSON map of metadata entry names to base64 data.
// A named entry returns bounded image bytes; nothing is extracted to disk.
NSData *HBRReadModArchive(NSURL *url, NSString *entry, NSError **error);
