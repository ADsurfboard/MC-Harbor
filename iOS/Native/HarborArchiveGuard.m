#import "HarborArchiveGuard.h"
#import "HarborModpackMetadata.h"
#import <UIKit/UIKit.h>
#import <HarborIOSUI/HarborIOSUI-Swift.h>
#import "UZKArchive.h"
#import "UZKFileInfo.h"
#import <sys/stat.h>

static BOOL HBRReject(NSError **error, NSString *message) {
    if (error) *error=[NSError errorWithDomain:@"net.morben.harbor.archive" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static unsigned long long HBRFreeSpace(NSString *destination) {
    NSString *parent=destination;
    while (![NSFileManager.defaultManager fileExistsAtPath:parent] && parent.length>1) parent=parent.stringByDeletingLastPathComponent;
    NSDictionary *attributes=[NSFileManager.defaultManager attributesOfFileSystemForPath:parent error:nil];
    return [attributes[NSFileSystemFreeSize] unsignedLongLongValue];
}
BOOL HBRValidateDestination(NSString *relative, NSString *destination, NSError **error) {
    if (![relative isKindOfClass:NSString.class] || relative.length==0 || relative.isAbsolutePath || [relative containsString:@"\\"] || [relative containsString:@":"]) return HBRReject(error,@"整合包包含无效的文件路径。");
    for (NSString *part in relative.pathComponents) if ([part isEqual:@".."] || [part isEqual:@"."]) return HBRReject(error,@"整合包文件路径超出实例目录。");
    NSString *root=destination.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString *resolved=[destination stringByAppendingPathComponent:relative].stringByStandardizingPath.stringByResolvingSymlinksInPath;
    if (![resolved hasPrefix:[root stringByAppendingString:@"/"]]) return HBRReject(error,@"整合包的目标路径包含越界链接。");
    return YES;
}
BOOL HBRValidateArchive(UZKArchive *archive, NSString *destination, NSError **error) {
    NSArray<UZKFileInfo *> *files=[archive listFileInfo:error]; if (!files) return NO;
    if (files.count>100000) return HBRReject(error,@"整合包内的文件数量过多。");
    NSMutableArray *entries=[NSMutableArray arrayWithCapacity:files.count];
    for (UZKFileInfo *file in files) {
        if (!HBRValidateDestination(file.filename,destination,error)) return NO;
        if (file.isEncryptedWithPassword) return HBRReject(error,@"请先解密整合包后再导入。");
        if ([file.filename isEqual:@"modrinth.index.json"] && file.uncompressedSize>8*1024*1024) return HBRReject(error,@"整合包索引文件过大。");
        [entries addObject:@{@"path":file.filename,@"compressedBytes":@(file.compressedSize),@"expandedBytes":@(file.uncompressedSize),@"symbolicLink":@((file.posixPermissions&S_IFMT)==S_IFLNK)}];
    }
    NSData *json=[NSJSONSerialization dataWithJSONObject:entries options:0 error:error];
    return json && [HarborArchiveSafety validateEntriesJSON:json availableBytes:HBRFreeSpace(destination) error:error];
}
BOOL HBRValidateRemoteFiles(NSArray *files, NSString *destination, NSError **error) {
    if (![files isKindOfClass:NSArray.class] || files.count>100000) return HBRReject(error,@"整合包的下载清单无效。");
    NSMutableArray *entries=[NSMutableArray arrayWithCapacity:files.count];
    for (id file in files) {
        if (!HBRValidateModpackRemoteFile(file,error) || !HBRValidateDestination(file[@"path"],destination,error)) return NO;
        if (!HBRModpackFileSupportsClient(file)) continue;
        [entries addObject:@{@"path":file[@"path"],@"compressedBytes":file[@"fileSize"],@"expandedBytes":file[@"fileSize"],@"symbolicLink":@NO}];
    }
    NSData *json=[NSJSONSerialization dataWithJSONObject:entries options:0 error:error];
    return json && [HarborArchiveSafety validateEntriesJSON:json availableBytes:HBRFreeSpace(destination) error:error];
}

// Bounded streaming avoids holding an entire mod JAR or resource pack in RAM.
void HBRExtractDirectory(UZKArchive *archive, NSString *directory, NSString *destination, NSError **error) {
    if (!HBRValidateArchive(archive,destination,error)) return;
    NSString *prefix=[directory stringByAppendingString:@"/"];
    [archive performOnFilesInArchive:^(UZKFileInfo *file, BOOL *stop) {
        if (![file.filename hasPrefix:prefix] || file.filename.length<=prefix.length) return;
        NSString *relative=[file.filename substringFromIndex:prefix.length];
        if (!HBRValidateDestination(relative,destination,error)) { *stop=YES; return; }
        NSString *target=[destination stringByAppendingPathComponent:relative];
        NSString *parent=file.isDirectory ? target : target.stringByDeletingLastPathComponent;
        if (![NSFileManager.defaultManager createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:error]) { *stop=YES; return; }
        if (file.isDirectory) return;
        NSString *temporary=[parent stringByAppendingPathComponent:[@".harbor-import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSOutputStream *output=[NSOutputStream outputStreamToFileAtPath:temporary append:NO]; [output open];
        __block BOOL failed=NO; __block unsigned long long written=0;
        BOOL extracted=[archive extractBufferedDataFromFile:file.filename error:error action:^(NSData *chunk, CGFloat progress) {
            if (failed) return;
            if (chunk.length>file.uncompressedSize || written>file.uncompressedSize-chunk.length) { failed=YES; HBRReject(error,@"解压数据超过索引声明的大小。"); return; }
            const uint8_t *bytes=chunk.bytes; NSUInteger offset=0;
            while (offset<chunk.length) {
                NSInteger count=[output write:bytes+offset maxLength:chunk.length-offset];
                if (count<=0) { failed=YES; if (error) *error=output.streamError ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:nil]; break; }
                offset+=count; written+=count;
            }
        }];
        [output close];
        if (failed || !extracted || written!=file.uncompressedSize || rename(temporary.fileSystemRepresentation,target.fileSystemRepresentation)!=0) {
            if (error && !*error) HBRReject(error,@"解压未完成，原有文件已保留。");
            [NSFileManager.defaultManager removeItemAtPath:temporary error:nil]; *stop=YES;
        }
    } error:error];
}
