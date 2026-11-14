#import "HarborModpackMetadata.h"
#include <math.h>
#include <CommonCrypto/CommonDigest.h>

static id HBRInvalid(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"net.morben.harbor.modpack" code:1
                                      userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}
static BOOL HBRSafeVersion(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 128) return NO;
    return [value rangeOfString:@"^[A-Za-z0-9][A-Za-z0-9._+\\-]{0,127}$" options:NSRegularExpressionSearch].location != NSNotFound;
}
// SHA-1 is retained only for Minecraft's existing official metadata. Modrinth
// payloads use SHA-512. Both stream through the same fixed 64 KiB buffer.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
NSString *HBRFileDigest(NSString *path, BOOL sha512, NSError **error) {
    if (![path isKindOfClass:NSString.class]) return HBRInvalid(error, @"校验文件路径无效。");
    NSString *resolved=path.stringByResolvingSymlinksInPath;
    NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:resolved error:error];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) return HBRInvalid(error, @"待校验文件不存在或不是普通文件。");
    unsigned long long size=[attributes[NSFileSize] unsignedLongLongValue], consumed=0;
    if (size>32ULL*1024*1024*1024) return HBRInvalid(error, @"待校验文件过大。");
    NSInputStream *input=[NSInputStream inputStreamWithFileAtPath:resolved];[input open];
    CC_SHA1_CTX one;CC_SHA512_CTX strong;
    if (sha512) CC_SHA512_Init(&strong);else CC_SHA1_Init(&one);
    uint8_t buffer[64*1024];NSInteger count;
    while ((count=[input read:buffer maxLength:sizeof(buffer)])>0) {
        if (consumed>size || (unsigned long long)count>size-consumed) {
            [input close];return HBRInvalid(error, @"校验期间文件发生变化，请重试。");
        }
        if (sha512) CC_SHA512_Update(&strong,buffer,(CC_LONG)count);else CC_SHA1_Update(&one,buffer,(CC_LONG)count);
        consumed+=(unsigned long long)count;
    }
    [input close];
    if (count<0 || consumed!=size) return HBRInvalid(error, @"文件未能完整读取，无法完成校验。");
    unsigned char digest[CC_SHA512_DIGEST_LENGTH];
    if (sha512) CC_SHA512_Final(digest,&strong);else CC_SHA1_Final(digest,&one);
    NSUInteger length=sha512 ? CC_SHA512_DIGEST_LENGTH:CC_SHA1_DIGEST_LENGTH;
    NSMutableString *hex=[NSMutableString stringWithCapacity:length*2];
    for (NSUInteger index=0;index<length;index++) [hex appendFormat:@"%02x",digest[index]];
    return hex;
}
#pragma clang diagnostic pop
NSDictionary *HBRParseModpackIndex(id data, NSError **error) {
    if (![data isKindOfClass:NSData.class] || ![data length] || [data length]>8*1024*1024)
        return HBRInvalid(error, @"整合包缺少有效的 modrinth.index.json，或索引超过 8 MiB。");
    id index=[NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![index isKindOfClass:NSDictionary.class]) return HBRInvalid(error, @"整合包索引必须是 JSON 对象。");
    id format=index[@"formatVersion"];
    if (![format isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)format)==CFBooleanGetTypeID() ||
        [format doubleValue]!=1.0 || ![index[@"game"] isEqual:@"minecraft"])
        return HBRInvalid(error, @"不支持的 Modrinth 整合包格式。");
    if (!HBRValidateModpackName(index[@"name"],error) || !HBRValidateModpackName(index[@"versionId"],error)) return nil;
    if (![index[@"files"] isKindOfClass:NSArray.class] || [index[@"files"] count]>100000 ||
        ![index[@"dependencies"] isKindOfClass:NSDictionary.class])
        return HBRInvalid(error, @"整合包下载清单或依赖格式无效。");
    return index;
}
BOOL HBRValidateModpackRemoteFile(id file, NSError **error) {
    if (![file isKindOfClass:NSDictionary.class] || ![file[@"path"] isKindOfClass:NSString.class] || ![file[@"path"] length]) {
        HBRInvalid(error, @"整合包下载条目无效。"); return NO;
    }
    id size=file[@"fileSize"];
    if (![size isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)size)==CFBooleanGetTypeID() ||
        !isfinite([size doubleValue]) || [size doubleValue]<0 || floor([size doubleValue])!=[size doubleValue] || [size doubleValue]>32.0*1024*1024*1024) {
        HBRInvalid(error, @"整合包文件大小无效。"); return NO;
    }
    NSArray *downloads=[file[@"downloads"] isKindOfClass:NSArray.class] ? file[@"downloads"] : nil;
    if (!downloads.count || downloads.count>8) { HBRInvalid(error,@"整合包下载地址数量无效。");return NO; }
    for (id raw in downloads) {
        NSURL *url=[raw isKindOfClass:NSString.class] ? [NSURL URLWithString:raw]:nil;
        if (![raw isKindOfClass:NSString.class] || ![raw length] || [raw length]>8192 ||
            [raw rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location!=NSNotFound ||
            ![url.scheme.lowercaseString isEqual:@"https"] || !url.host.length || url.user || url.password || (url.port && url.port.integerValue!=443) ||
            ![@[@"cdn.modrinth.com",@"github.com",@"raw.githubusercontent.com",@"gitlab.com"] containsObject:url.host.lowercaseString]) {
            HBRInvalid(error, @"整合包下载地址不属于当前支持的 Modrinth HTTPS 域名。"); return NO;
        }
    }
    NSDictionary *hashes=[file[@"hashes"] isKindOfClass:NSDictionary.class] ? file[@"hashes"] : nil;
    NSCharacterSet *notHex=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
    for (NSString *key in @[@"sha1",@"sha512"]) {
        NSString *value=[hashes[key] isKindOfClass:NSString.class] ? hashes[key] : nil;
        if (value.length!=([key isEqual:@"sha1"] ? 40:128) || [value rangeOfCharacterFromSet:notHex].location!=NSNotFound) {
            HBRInvalid(error, @"整合包缺少有效的 SHA-1 / SHA-512 校验值。"); return NO;
        }
    }
    id env=file[@"env"];
    if (env && ![env isKindOfClass:NSDictionary.class]) { HBRInvalid(error, @"整合包兼容声明无效。"); return NO; }
    for (NSString *side in @[@"client",@"server"]) {
        if (env[side] && ![@[@"required",@"optional",@"unsupported"] containsObject:env[side]]) {
            HBRInvalid(error, @"整合包兼容声明无效。"); return NO;
        }
    }
    return YES;
}
BOOL HBRModpackFileSupportsClient(NSDictionary *file) {
    id env=file[@"env"];
    return !env || ([env isKindOfClass:NSDictionary.class] && ![env[@"client"] isEqual:@"unsupported"]);
}
BOOL HBRValidateModpackName(id name, NSError **error) {
    if (![name isKindOfClass:NSString.class] || ![name length] || [name length] > 256 ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        HBRInvalid(error, @"整合包名称无效。"); return NO;
    }
    return YES;
}
NSString *HBRUniqueModpackName(NSString *name, NSDictionary *profiles) {
    if (!profiles[name]) return name;
    for (NSUInteger number = 2; number < 10000; number++) {
        NSString *candidate = [NSString stringWithFormat:@"%@ (%lu)", name, (unsigned long)number];
        if (!profiles[candidate]) return candidate;
    }
    return [name stringByAppendingFormat:@" (%@)", NSUUID.UUID.UUIDString];
}
NSString *HBRNewModpackStorageName(void) {
    return [@"pack-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
}
BOOL HBRIsModpackStorageName(id name) {
    if (![name isKindOfClass:NSString.class] || [name length]!=41 || ![name hasPrefix:@"pack-"]) return NO;
    NSUUID *identifier=[[NSUUID alloc] initWithUUIDString:[name substringFromIndex:5]];
    return identifier && [[@"pack-" stringByAppendingString:identifier.UUIDString.lowercaseString] isEqual:name];
}

NSDictionary *HBRResolveModpackDependencies(id dependencies, NSString *versionsDirectory, NSError **error) {
    if (![dependencies isKindOfClass:NSDictionary.class] || !HBRSafeVersion(dependencies[@"minecraft"]))
        return HBRInvalid(error, @"整合包缺少有效的 Minecraft 版本。");
    NSSet *known = [NSSet setWithArray:@[@"minecraft", @"fabric-loader", @"quilt-loader", @"forge", @"neoforge"]];
    NSString *loader = nil, *loaderVersion = nil;
    for (id key in dependencies) {
        if (![key isKindOfClass:NSString.class] || ![known containsObject:key] || !HBRSafeVersion(dependencies[key]))
            return HBRInvalid(error, @"整合包包含无效或不支持的依赖。");
        if ([key isEqual:@"minecraft"]) continue;
        if (loader) return HBRInvalid(error, @"整合包同时指定了多个模组加载器。");
        loader = key; loaderVersion = dependencies[key];
    }
    NSString *minecraft = dependencies[@"minecraft"];
    if (!loader) return @{@"id":minecraft};
    if ([loader isEqual:@"fabric-loader"] || [loader isEqual:@"quilt-loader"])
        return @{@"id":[NSString stringWithFormat:@"%@-%@-%@",loader,loaderVersion,minecraft]};

    // Forge/NeoForge use their actual installed metadata ID, including custom
    // profile names. Do not invent an ID or create an unlaunchable pack profile.
    if (![versionsDirectory isKindOfClass:NSString.class] || !versionsDirectory.length)
        return HBRInvalid(error, @"请先安装整合包要求的加载器。");
    NSString *root = versionsDirectory.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSArray *directories = [NSFileManager.defaultManager contentsOfDirectoryAtPath:versionsDirectory error:nil];
    NSString *expected = [loader isEqual:@"forge"] ?
        [NSString stringWithFormat:@"net.minecraftforge:forge:%@-%@", minecraft, loaderVersion] :
        [@"net.neoforged:neoforge:" stringByAppendingString:loaderVersion];
    for (NSString *directory in [directories sortedArrayUsingSelector:@selector(compare:)]) { @autoreleasepool {
        // User-created local version names can contain Chinese and spaces.
        if (!directory.length || directory.length > 256 || [directory isEqual:@"."] || [directory isEqual:@".."] ||
            [directory rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
            [directory rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:"]].location != NSNotFound) continue;
        NSString *path = [[versionsDirectory stringByAppendingPathComponent:directory]
                          stringByAppendingPathComponent:[directory stringByAppendingString:@".json"]];
        if (![path.stringByStandardizingPath.stringByResolvingSymlinksInPath hasPrefix:[root stringByAppendingString:@"/"]]) continue;
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if (!attributes || [attributes[NSFileSize] unsignedLongLongValue] > 4 * 1024 * 1024) continue;
        NSData *data = [NSData dataWithContentsOfFile:path];
        id metadata = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![metadata isKindOfClass:NSDictionary.class] || ![metadata[@"inheritsFrom"] isEqual:minecraft] ||
            ![metadata[@"libraries"] isKindOfClass:NSArray.class]) continue;
        for (id library in metadata[@"libraries"]) {
            NSString *name=[library isKindOfClass:NSDictionary.class] && [library[@"name"] isKindOfClass:NSString.class] ? library[@"name"] : nil;
            if ([name isEqual:expected] || [name hasPrefix:[expected stringByAppendingString:@":"]])
                return @{@"id":directory};
        }
    } }
    return HBRInvalid(error, [NSString stringWithFormat:@"请先安装 Minecraft %@ 对应的 %@ %@，再导入此整合包。自动运行该加载器的安装流程仍在适配。", minecraft, loader, loaderVersion]);
}
