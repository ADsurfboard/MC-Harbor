#import <Foundation/Foundation.h>

/// Public game/loader resources only. Account and auth-server requests must
/// never pass through these mirrors or inherit their routing policy.
NSArray<NSURL *> *HBRPublicDownloadURLs(NSURL *original, NSString *route);
NSString *HBRPublicDownloadRoute(void);
typedef NS_ENUM(NSInteger, HBRMetadataFormat) { HBRMetadataDictionary, HBRMetadataArray, HBRMetadataXML };
void HBRFetchPublicMetadata(NSURL *url, HBRMetadataFormat format,
                           NSString *route,
                           NSURLSessionConfiguration *testConfiguration,
                           void (^completion)(id object, NSError *error));
void HBRPublicGET(NSString *url, HBRMetadataFormat format,
                  void (^success)(NSURLSessionTask *,id), void (^failure)(NSURLSessionTask *,NSError *));
NSData *HBRReadPublicXML(NSURL *url,NSError **error);
