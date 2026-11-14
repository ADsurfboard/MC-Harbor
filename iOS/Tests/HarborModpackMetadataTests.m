#import <Foundation/Foundation.h>
#import "HarborModpackMetadata.h"

static NSUInteger checks;
#define CHECK(value) do { checks++; if (!(value)) { NSLog(@"FAILED line %d: %s", __LINE__, #value); return 1; } } while (0)

static void writeVersion(NSString *root, NSString *identifier, NSString *minecraft, NSString *library) {
    NSString *directory = [root stringByAppendingPathComponent:identifier];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"id":identifier, @"inheritsFrom":minecraft,
        @"libraries":@[@{@"name":library}]} options:0 error:nil];
    [data writeToFile:[directory stringByAppendingPathComponent:[identifier stringByAppendingString:@".json"]] atomically:YES];
}

int main(void) { @autoreleasepool {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    @try {
        CHECK(HBRResolveModpackDependencies(nil, root, nil) == nil);
        CHECK(HBRResolveModpackDependencies(@{}, root, nil) == nil);
        CHECK(HBRResolveModpackDependencies(@{@"minecraft":@"../escape"}, root, nil) == nil);
        CHECK(HBRResolveModpackDependencies(@{@"minecraft":@"1.20.1/evil"}, root, nil) == nil);
        CHECK(HBRResolveModpackDependencies(@{@"minecraft":@YES}, root, nil) == nil);
        CHECK([HBRResolveModpackDependencies(@{@"minecraft":@"1.20.1"}, root, nil)[@"id"] isEqual:@"1.20.1"]);
        CHECK([HBRResolveModpackDependencies(@{@"minecraft":@"1.20.1", @"fabric-loader":@"0.16.9"}, root, nil)[@"id"] isEqual:@"fabric-loader-0.16.9-1.20.1"]);
        CHECK([HBRResolveModpackDependencies(@{@"minecraft":@"1.20.1", @"quilt-loader":@"0.26.4"}, root, nil)[@"id"] isEqual:@"quilt-loader-0.26.4-1.20.1"]);
        CHECK(HBRResolveModpackDependencies(@{@"minecraft":@"1.20.1", @"fabric-loader":@".."}, root, nil) == nil);
        CHECK(HBRResolveModpackDependencies(@{@"minecraft":@"1.20.1", @"forge":@"47.2.0", @"fabric-loader":@"0.16.9"}, root, nil) == nil);
        CHECK(HBRResolveModpackDependencies(@{@"minecraft":@"1.20.1", @"unknown-loader":@"1"}, root, nil) == nil);
        NSError *missing = nil;
        CHECK(HBRResolveModpackDependencies(@{@"minecraft":@"1.20.1", @"forge":@"47.2.0"}, root, &missing) == nil);
        CHECK(missing != nil);
        writeVersion(root, @"custom-forge", @"1.20.1", @"net.minecraftforge:forge:1.20.1-47.2.0");
        CHECK([HBRResolveModpackDependencies(@{@"minecraft":@"1.20.1", @"forge":@"47.2.0"}, root, nil)[@"id"] isEqual:@"custom-forge"]);
        CHECK(HBRResolveModpackDependencies(@{@"minecraft":@"1.19.4", @"forge":@"47.2.0"}, root, nil) == nil);
        writeVersion(root, @"我的 Forge", @"1.20.1", @"net.minecraftforge:forge:1.20.1-47.3.0:universal");
        CHECK([HBRResolveModpackDependencies(@{@"minecraft":@"1.20.1", @"forge":@"47.3.0"}, root, nil)[@"id"] isEqual:@"我的 Forge"]);
        writeVersion(root, @"custom-neo", @"1.21.1", @"net.neoforged:neoforge:21.1.50:client");
        CHECK([HBRResolveModpackDependencies(@{@"minecraft":@"1.21.1", @"neoforge":@"21.1.50"}, root, nil)[@"id"] isEqual:@"custom-neo"]);
        CHECK(HBRResolveModpackDependencies(@{@"minecraft":@"1.21.1", @"neoforge":@"21.1.5"}, root, nil) == nil);
        CHECK(!HBRValidateModpackName(nil, nil));
        CHECK(!HBRValidateModpackName(@"", nil));
        CHECK(!HBRValidateModpackName(@"pack\nname", nil));
        CHECK(HBRValidateModpackName(@"中文 / Pack 的显示名称", nil));
        NSDictionary *profiles = @{@"原实例":@{}, @"原实例 (2)":@{}};
        CHECK([HBRUniqueModpackName(@"原实例", profiles) isEqual:@"原实例 (3)"]);
        CHECK(profiles.count == 2);
        NSMutableSet *storage = [NSMutableSet set];
        for (NSUInteger i=0; i<20; i++) {
            NSString *name = HBRNewModpackStorageName();
            CHECK(HBRIsModpackStorageName(name));
            CHECK([name hasPrefix:@"pack-"] && ![name containsString:@"/"] && ![name containsString:@".."]);
            [storage addObject:name];
        }
        CHECK(storage.count == 20);
        for (id invalid in @[@"pack-../escape",@"pack-invalid",@"pack-00000000-0000-0000-0000-000000000000/../a",@12,NSNull.null]) CHECK(!HBRIsModpackStorageName(invalid));
        NSDictionary *valid=@{@"path":@"mods/example.jar", @"fileSize":@1,
            @"downloads":@[@"https://cdn.modrinth.com/data/example.jar"],
            @"hashes":@{@"sha1":[@"" stringByPaddingToLength:40 withString:@"a" startingAtIndex:0],
                         @"sha512":[@"" stringByPaddingToLength:128 withString:@"b" startingAtIndex:0]}};
        CHECK(HBRValidateModpackRemoteFile(valid,nil));
        CHECK(HBRModpackFileSupportsClient(valid));
        CHECK(!HBRValidateModpackRemoteFile(nil,nil));
        for (id size in @[@(-1),@1.5,@YES,@(INFINITY),@(33.0*1024*1024*1024)]) {
            NSMutableDictionary *file=valid.mutableCopy;file[@"fileSize"]=size;
            CHECK(!HBRValidateModpackRemoteFile(file,nil));
        }
        for (NSString *url in @[@"http://cdn.modrinth.com/a",@"https://localhost/a",@"https://example.com/a",
                                @"https://user:password@github.com/a",@"https://cdn.modrinth.com/a b",@"https://cdn.modrinth.com:8443/a",@"https://@cdn.modrinth.com/a"]) {
            NSMutableDictionary *file=valid.mutableCopy;file[@"downloads"]=@[url];
            CHECK(!HBRValidateModpackRemoteFile(file,nil));
        }
        for (id second in @[@"http://cdn.modrinth.com/a",@"https://localhost/a",@12,NSNull.null]) {
            NSMutableDictionary *alternate=valid.mutableCopy;alternate[@"downloads"]=@[valid[@"downloads"][0],second];
            CHECK(!HBRValidateModpackRemoteFile(alternate,nil));
        }
        NSMutableDictionary *file=valid.mutableCopy;file[@"hashes"]=@{};
        CHECK(!HBRValidateModpackRemoteFile(file,nil));
        file=valid.mutableCopy;file[@"hashes"]=@"bad";
        CHECK(!HBRValidateModpackRemoteFile(file,nil));
        file=valid.mutableCopy;file[@"env"]=@{@"client":@"unsupported",@"server":@"required"};
        CHECK(HBRValidateModpackRemoteFile(file,nil));
        CHECK(!HBRModpackFileSupportsClient(file));
        file[@"env"]=@{@"client":@"optional"};
        CHECK(HBRValidateModpackRemoteFile(file,nil) && HBRModpackFileSupportsClient(file));
        file[@"env"]=@{@"client":@"unknown"};
        CHECK(!HBRValidateModpackRemoteFile(file,nil));
        file[@"env"]=@"invalid";
        CHECK(!HBRValidateModpackRemoteFile(file,nil));
        CHECK(!HBRModpackFileSupportsClient(file));
        NSDictionary *index=@{@"formatVersion":@1,@"game":@"minecraft",@"name":@"测试整合包",@"versionId":@"v1",
                             @"files":@[],@"dependencies":@{@"minecraft":@"1.20.1"}};
        CHECK(HBRParseModpackIndex([NSJSONSerialization dataWithJSONObject:index options:0 error:nil],nil) != nil);
        CHECK(HBRParseModpackIndex(nil,nil) == nil);
        CHECK(HBRParseModpackIndex([NSData data],nil) == nil);
        CHECK(HBRParseModpackIndex([@"not JSON" dataUsingEncoding:NSUTF8StringEncoding],nil) == nil);
        CHECK(HBRParseModpackIndex([@"[]" dataUsingEncoding:NSUTF8StringEncoding],nil) == nil);
        CHECK(HBRParseModpackIndex([NSMutableData dataWithLength:8*1024*1024+1],nil) == nil);
        for (id format in @[@YES,@1.5,@2,@"1"]) {
            NSMutableDictionary *invalid=index.mutableCopy;invalid[@"formatVersion"]=format;
            CHECK(HBRParseModpackIndex([NSJSONSerialization dataWithJSONObject:invalid options:0 error:nil],nil) == nil);
        }
        NSMutableDictionary *invalid=index.mutableCopy;[invalid removeObjectForKey:@"versionId"];
        CHECK(HBRParseModpackIndex([NSJSONSerialization dataWithJSONObject:invalid options:0 error:nil],nil) == nil);
        invalid=index.mutableCopy;invalid[@"files"]=@"not an array";
        CHECK(HBRParseModpackIndex([NSJSONSerialization dataWithJSONObject:invalid options:0 error:nil],nil) == nil);
        NSString *hashFile=[root stringByAppendingPathComponent:@"hash-fixture.bin"];
        [[@"abc" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:hashFile atomically:YES];
        CHECK([HBRFileDigest(hashFile,NO,nil) isEqual:@"a9993e364706816aba3e25717850c26c9cd0d89d"]);
        CHECK([HBRFileDigest(hashFile,YES,nil) isEqual:@"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"]);
        CHECK(HBRFileDigest([root stringByAppendingPathComponent:@"missing"],YES,nil)==nil);
        CHECK(HBRFileDigest(root,NO,nil)==nil);
        [[NSData data] writeToFile:hashFile atomically:YES];
        CHECK([HBRFileDigest(hashFile,NO,nil) isEqual:@"da39a3ee5e6b4b0d3255bfef95601890afd80709"]);
        NSMutableData *chunks=[NSMutableData dataWithLength:3*65536+17];
        memset(chunks.mutableBytes,'Z',chunks.length);[chunks writeToFile:hashFile atomically:YES];
        CHECK([HBRFileDigest(hashFile,NO,nil) isEqual:@"eb8e85f15f13586d54c17d4c6298f951744b8901"]);
        CHECK([HBRFileDigest(hashFile,YES,nil) isEqual:@"ccaa3d3d79cc8d1b5827957b9da2ede1e8f830809352ea16ad76d24f3e64f75c52285009955496e3b8409d05b3d2938ade30b967ac2f0433c9ef22fd7d83ccad"]);
        printf("Harbor modpack metadata: %lu checks passed; only disposable fixtures used.\n", (unsigned long)checks);
    } @finally {
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    }
    return 0;
} }
