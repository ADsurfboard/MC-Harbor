#import "HarborModArchive.h"
#import "UZKArchive.h"
#import "UZKFileInfo.h"
#import <sys/stat.h>

static NSData *HBRModFailure(NSError **error, NSString *message) {
    if (error) *error=[NSError errorWithDomain:@"net.morben.harbor.modinfo" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}
static NSData *HBRModEntry(UZKArchive *archive, UZKFileInfo *entry, NSUInteger limit, NSError **error) {
    if (entry.isDirectory || entry.isEncryptedWithPassword || (entry.posixPermissions&S_IFMT)==S_IFLNK || entry.uncompressedSize>limit)
        return HBRModFailure(error,@"模组资料条目被加密、包含链接或超过大小上限。");
    NSMutableData *data=[NSMutableData data]; __block BOOL failed=NO;
    BOOL success=[archive extractBufferedDataFromFile:entry.filename error:error action:^(NSData *chunk, CGFloat progress) {
        if (failed) return;
        if (chunk.length>limit || data.length>limit-chunk.length) { failed=YES; return; }
        [data appendData:chunk];
    }];
    if (!success || failed || data.length!=entry.uncompressedSize)
        return HBRModFailure(error,@"模组资料未完整读取，原文件未改动。");
    return data;
}
NSData *HBRReadModArchive(NSURL *url, NSString *entry, NSError **error) {
    BOOL languages=[entry isEqual:@"@harbor-language-files"];
    if (!url.isFileURL) return HBRModFailure(error,@"请选择本地 JAR 文件。");
    if (entry && (entry.length>512 || entry.isAbsolutePath || [entry containsString:@"\\"] || [entry containsString:@":"] ||
                  [entry.pathComponents containsObject:@".."] || [entry.pathComponents containsObject:@"."]))
        return HBRModFailure(error,@"图标条目路径无效。");
    BOOL scoped=[url startAccessingSecurityScopedResource];
    __block NSData *result=nil; __block NSError *failure=nil; NSError *coordination=nil;
    [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&coordination byAccessor:^(NSURL *readable) {
        NSDictionary *attributes=[readable resourceValuesForKeys:@[NSURLIsRegularFileKey,NSURLIsSymbolicLinkKey,NSURLFileSizeKey] error:&failure];
        if (!attributes || ![attributes[NSURLIsRegularFileKey] boolValue] || [attributes[NSURLIsSymbolicLinkKey] boolValue] ||
            [attributes[NSURLFileSizeKey] unsignedLongLongValue]>1000000000ULL) {
            HBRModFailure(&failure,@"请选择小于 1 GB 的普通 JAR 模组文件。"); return;
        }
        UZKArchive *archive=[[UZKArchive alloc] initWithPath:readable.path error:&failure];
        NSArray<UZKFileInfo *> *files=[archive listFileInfo:&failure];
        if (!files || files.count>100000) { if (!failure) HBRModFailure(&failure,@"模组归档文件数量过多。"); return; }
        NSMutableArray *languageNames=[NSMutableArray array];
        NSMutableDictionary<NSString *,UZKFileInfo *> *languageFiles=[NSMutableDictionary dictionary];
        if (languages) {
            NSRegularExpression *pattern=[NSRegularExpression regularExpressionWithPattern:@"^assets/[a-z0-9_.-]+/lang/[a-z]{2,3}_[a-z0-9]{2,6}\\.(json|lang)$" options:NSRegularExpressionCaseInsensitive error:&failure];
            NSMutableSet *seen=[NSMutableSet set]; unsigned long long expanded=0;
            for (UZKFileInfo *file in files) if ([pattern numberOfMatchesInString:file.filename options:0 range:NSMakeRange(0,file.filename.length)]) {
                NSString *key=file.filename.precomposedStringWithCanonicalMapping.lowercaseString;
                if ([seen containsObject:key] || languageNames.count>=2048 || file.uncompressedSize>4*1024*1024 || expanded+file.uncompressedSize>24*1024*1024) {
                    HBRModFailure(&failure,@"语言文件重复、数量过多或文本总量超过 24 MB，请分批处理。");return;
                }
                [seen addObject:key];[languageNames addObject:file.filename];languageFiles[file.filename]=file;expanded+=file.uncompressedSize;
            }
        }
        NSArray *names=languages ? languageNames:(entry ? @[entry] : @[@"fabric.mod.json",@"quilt.mod.json",@"META-INF/neoforge.mods.toml",@"META-INF/mods.toml",@"mcmod.info",@"META-INF/MANIFEST.MF"]);
        NSMutableDictionary *entries=[NSMutableDictionary dictionary];
        for (NSString *name in names) {
            UZKFileInfo *found=languages ? languageFiles[name]:nil;
            if (!languages) for (UZKFileInfo *file in files) if ([file.filename isEqual:name]) {
                if (found) { HBRModFailure(&failure,@"模组包含重复的资料条目。"); return; }
                found=file;
            }
            if (!found) continue;
            NSData *bytes=HBRModEntry(archive,found,languages ? 4*1024*1024:(entry ? 512*1024:1024*1024),&failure);
            if (!bytes) return;
            if (entry && !languages) { result=bytes; return; }
            entries[name]=[bytes base64EncodedStringWithOptions:0];
        }
        if (!entry || languages) result=[NSJSONSerialization dataWithJSONObject:entries options:0 error:&failure];
        else HBRModFailure(&failure,@"模组未包含声明的图标。");
    }];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (error) *error=coordination ?: failure;
    return result;
}
