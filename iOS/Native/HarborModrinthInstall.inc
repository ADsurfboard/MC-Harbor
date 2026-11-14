// Included in the pinned ModrinthAPI implementation. All unpacked payload stays
// private until downloads, checksums and both override passes have completed.
- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        if (downloader.progress.cancelled) return;
        NSError *error=nil;
        UZKArchive *archive=[[UZKArchive alloc] initWithPath:packagePath error:&error];
        if (!archive || error || !HBRValidateArchive(archive,destPath,&error)) {
            dispatch_async(dispatch_get_main_queue(),^{[downloader finishDownloadWithErrorString:error.localizedDescription ?: @"无法读取整合包。"];});return;
        }
        NSDictionary *index=HBRParseModpackIndex([archive extractDataFromFile:@"modrinth.index.json" error:&error],&error);
        NSString *gameRoot=NSProcessInfo.processInfo.environment[@"GAME_DIR"];
        NSString *versions=[gameRoot stringByAppendingPathComponent:@"versions"];
        NSDictionary *resolved=index ? HBRResolveModpackDependencies(index[@"dependencies"],versions,&error):nil;
        if (!gameRoot.length || !resolved || !HBRValidateRemoteFiles(index[@"files"],destPath,&error)) {
            dispatch_async(dispatch_get_main_queue(),^{[downloader finishDownloadWithErrorString:error.localizedDescription ?: @"整合包依赖尚未准备好。"];});return;
        }
        NSDictionary *dependencies=[ModpackUtils infoForDependencies:index[@"dependencies"]];
        NSString *version=resolved[@"id"];
        NSString *versionPath=[[versions stringByAppendingPathComponent:version] stringByAppendingPathComponent:[version stringByAppendingString:@".json"]];
        NSMutableArray *files=[NSMutableArray new];
        for (NSDictionary *file in index[@"files"]) if (HBRModpackFileSupportsClient(file)) [files addObject:file];
        NSString *iconPath=[NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
        NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:iconPath error:nil];
        NSData *icon=!downloader.harborLocalImport && attributes && [attributes[NSFileSize] unsignedLongLongValue]<=512*1024 ? [NSData dataWithContentsOfFile:iconPath]:nil;
        BOOL (^validLoader)(NSData *)=^BOOL(NSData *data) {
            if (!data.length || data.length>4*1024*1024) return NO;
            id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            return [json isKindOfClass:NSDictionary.class] && [json[@"id"] isEqual:version] &&
                [json[@"inheritsFrom"] isEqual:index[@"dependencies"][@"minecraft"]] &&
                [json[@"libraries"] isKindOfClass:NSArray.class] && [json[@"libraries"] count]>0 &&
                [json[@"mainClass"] isKindOfClass:NSString.class] && [json[@"mainClass"] length]>0;
        };
        dispatch_async(dispatch_get_main_queue(),^{
            if (downloader.progress.cancelled) return;
            void (^begin)(NSData *)=^(NSData *loaderJSON) {
                if (downloader.progress.cancelled) return;
                HBRModpackTransaction *transaction=[[HBRModpackTransaction alloc]
                    initWithDestination:[NSURL fileURLWithPath:destPath isDirectory:YES] files:files
                    applyOverrides:^BOOL(NSURL *stage,NSError **failure) {
                        [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:stage.path error:failure];
                        if (failure && *failure) return NO;
                        if (downloader.progress.cancelled) return NO;
                        [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:stage.path error:failure];
                        return !(failure && *failure);
                    } commit:^BOOL(NSURL *destination,NSError **failure) {
                        // A valid newly downloaded loader profile is shared
                        // cache. Existing metadata is never blindly replaced.
                        if (loaderJSON) {
                            if ([NSFileManager.defaultManager fileExistsAtPath:versionPath]) {
                                NSDictionary *info=[NSFileManager.defaultManager attributesOfItemAtPath:versionPath error:failure];
                                if (!info || [info[NSFileSize] unsignedLongLongValue]>4*1024*1024 || !validLoader([NSData dataWithContentsOfFile:versionPath])) {
                                    if (failure) *failure=[NSError errorWithDomain:@"net.morben.harbor.import" code:2 userInfo:@{NSLocalizedDescriptionKey:@"加载器元数据已经变化，原文件未修改。"}];return NO;
                                }
                            } else {
                                if (![NSFileManager.defaultManager createDirectoryAtPath:versionPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:failure] ||
                                    ![loaderJSON writeToFile:versionPath options:NSDataWritingAtomic error:failure]) return NO;
                            }
                        }
                        [PLProfiles updateCurrent];PLProfiles *current=PLProfiles.current;
                        NSString *name=HBRUniqueModpackName(index[@"name"],current.profiles);
                        NSMutableDictionary *profile=@{@"gameDir":[@"./custom_gamedir/" stringByAppendingString:destination.lastPathComponent],@"name":name,@"lastVersionId":version}.mutableCopy;
                        if (icon.length) profile[@"icon"]=[@"data:image/png;base64," stringByAppendingString:[icon base64EncodedStringWithOptions:0]];
                        NSMutableDictionary *profiles=current.profiles.mutableCopy;profiles[name]=profile;
                        NSMutableDictionary *document=current.profileDict.mutableCopy;document[@"profiles"]=profiles;document[@"selectedProfile"]=name;
                        NSError *saveError=saveJSONToFile(document,current.profilePath);
                        if (saveError) {if (failure) *failure=saveError;return NO;}
                        current.profileDict=document;return YES;
                    } completion:^(NSError *failure) {
                        if (failure) {
                            if (!downloader.progress.cancelled) [downloader finishDownloadWithErrorString:failure.localizedDescription];
                            return;
                        }
                        // Only the UUID cache generated by this downloader may
                        // be deleted. A Files-selected player archive is kept.
                        NSString *cache=packagePath.stringByStandardizingPath;
                        if ([cache.stringByDeletingLastPathComponent isEqual:NSTemporaryDirectory().stringByStandardizingPath] &&
                            [cache.lastPathComponent isEqual:[destPath.lastPathComponent stringByAppendingString:@".zip"]] &&
                            [destPath.lastPathComponent hasPrefix:@"pack-"])
                            [NSFileManager.defaultManager removeItemAtPath:cache error:nil];
                        downloader.progress.completedUnitCount+=1;
                    }];
                [downloader.progress addChild:transaction.progress withPendingUnitCount:files.count+2];
                downloader.progress.totalUnitCount+=files.count+2;
                downloader.textProgress.totalUnitCount=downloader.progress.totalUnitCount;
                [downloader.fileList addObject:@"下载并校验整合包文件，应用覆盖配置，保存实例"];
                [downloader.progressList addObject:transaction.progress];
                [transaction start];
            };
            if (!dependencies[@"json"]) {begin(nil);return;}
            if ([NSFileManager.defaultManager fileExistsAtPath:versionPath]) {
                NSDictionary *info=[NSFileManager.defaultManager attributesOfItemAtPath:versionPath error:nil];
                if ([info[NSFileSize] unsignedLongLongValue]<=4*1024*1024 && validLoader([NSData dataWithContentsOfFile:versionPath])) begin(nil);
                else [downloader finishDownloadWithErrorString:@"现有加载器元数据无效，请先修复；原文件已保留。"];
                return;
            }
            NSString *temporary=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"harbor-loader-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            NSURLSessionDownloadTask *task=[downloader createDownloadTask:dependencies[@"json"] size:0 sha:nil altName:@"加载器元数据" toPath:temporary success:^{
                NSDictionary *info=[NSFileManager.defaultManager attributesOfItemAtPath:temporary error:nil];
                NSData *data=info && [info[NSFileSize] unsignedLongLongValue]<=4*1024*1024 ? [NSData dataWithContentsOfFile:temporary]:nil;
                [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
                if (!validLoader(data)) {[downloader finishDownloadWithErrorString:@"加载器返回的版本信息无效，未创建实例。"];return;}
                begin(data);
            }];
            [task resume];
        });
    });
}
