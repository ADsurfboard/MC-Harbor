package net.morben.shenggan;

import com.google.gson.*;
import org.jackhuang.hmcl.auth.*;
import org.jackhuang.hmcl.auth.microsoft.*;
import org.jackhuang.hmcl.auth.authlibinjector.*;
import org.jackhuang.hmcl.auth.offline.OfflineAccountFactory;
import org.jackhuang.hmcl.setting.NativeAccountMigration;
import org.jackhuang.hmcl.download.*;
import org.jackhuang.hmcl.game.*;
import org.jackhuang.hmcl.java.*;
import org.jackhuang.hmcl.launch.*;
import org.jackhuang.hmcl.modpack.Modpack;
import org.jackhuang.hmcl.modpack.multimc.MultiMCInstanceConfiguration;
import org.jackhuang.hmcl.modpack.multimc.MultiMCModpackExportTask;
import org.jackhuang.hmcl.task.*;
import org.jackhuang.hmcl.util.gson.JsonUtils;
import org.jackhuang.hmcl.util.io.JarUtils;
import org.jackhuang.hmcl.util.StringUtils;
import org.jackhuang.hmcl.util.platform.Platform;
import org.jackhuang.hmcl.util.platform.ManagedProcess;
import org.jackhuang.hmcl.util.versioning.VersionNumber;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicLong;
import java.util.zip.*;

/** JSON-line adapter for the unmodified, stable HMCL game engine; no JavaFX window is created. */
public final class NativeBridge {
    private static final PrintWriter protocol=new PrintWriter(new OutputStreamWriter(new FileOutputStream(FileDescriptor.out),StandardCharsets.UTF_8),true);
    private static JsonObject request;
    private static Path data;
    private static Repository repository;
    private static DefaultDependencyManager dependency;
    private static DownloadProvider provider;
    private static final AtomicLong lastProgress=new AtomicLong();

    public static void main(String[] args){
        System.setProperty("shenggan.headless","true");
        System.setOut(new PrintStream(new FileOutputStream(FileDescriptor.err),true,StandardCharsets.UTF_8));
        try{
            request=JsonParser.parseReader(new InputStreamReader(System.in,StandardCharsets.UTF_8)).getAsJsonObject();
            data=Path.of(System.getProperty("hmcl.dir")).toAbsolutePath().normalize();Files.createDirectories(data);
            org.jackhuang.hmcl.util.CacheRepository.getInstance().changeDirectory(data);
            String command=text("command","");
            if(command.equals("login")){result(login());System.exit(0);}
            if(command.equals("migrate")){result(migrate());System.exit(0);}
            if(command.equals("diagnostics")){result(diagnostics());System.exit(0);}
            if(command.equals("worldRead")||command.equals("worldSave")){NativeWorldEditor editor=new NativeWorldEditor(request,data);result(command.equals("worldRead")?editor.read():editor.save());System.exit(0);}
            if(command.equals("profile")||command.equals("applySkin")){
                JsonObject stored=request.getAsJsonObject("account");String type=text("accountType","offline");Account account=restore(type,stored.getAsJsonObject("hmclMetadata"),stored.getAsJsonObject("privateData"));
                Map<String,Object> profile=command.equals("applySkin")?NativeProfiles.apply(account,Path.of(text("skinFile","")),request.has("slim")&&request.get("slim").getAsBoolean(),data):NativeProfiles.describe(account,data,request.has("refresh")&&request.get("refresh").getAsBoolean());
                emit(Map.of("event","accountUpdated","data",serialize(account,type)));result(profile);System.exit(0);
            }
            Path root=Path.of(text("root","/Applications/.minecraft")).toAbsolutePath().normalize();
            repository=new Repository(root,text("runDirectory",""));repository.refreshVersions();
            DownloadProvider official=new MojangDownloadProvider(),mirror=new BMCLAPIDownloadProvider("https://bmclapi2.bangbang93.com");
            provider=text("source","auto").equals("mirror")?new AutoDownloadProvider(mirror,official):new AutoDownloadProvider(official,mirror);
            FetchTask.setDownloadExecutorConcurrency(Math.max(4,Math.min(24,integer("threads",8))));
            dependency=new DefaultDependencyManager(repository,provider,new DefaultCacheRepository(root));
            Map<String,Object> output=switch(command){
                case "mods"->mods();case "resources"->resources();case "loaders"->loaders();case "install"->install();case "repair"->repair();
                case "langScan"->languageScan();case "langRead"->new NativeLocalization(request,data).read();case "langSave"->new NativeLocalization(request,data).save();
                case "langTranslate"->new NativeLocalization(request,data).translate();case "langImport"->new NativeLocalization(request,data).importTranslations();case "langExport"->new NativeLocalization(request,data).export();case "langApply"->new NativeLocalization(request,data).applyTextAssets();
                case "launch"->launch();case "import"->importPack();case "backup"->backup(false);case "export"->exportPack();
                case "dependencyScan"->new NativeDependencies(request,data,provider,NativeBridge::stage).scan();
                case "dependencyComplete"->new NativeDependencies(request,data,provider,NativeBridge::stage).complete();
                case "runtime"->Map.of("path",compatibleJava(GameJavaVersion.get(integer("major",25))).getBinary().toString());
                case "cfSearch"->new NativeResources(request,provider).search();case "cfVersions"->new NativeResources(request,provider).versions();case "cfPlan"->new NativeResources(request,provider).plan();
                case "installWorld"->NativeWorldImport.install(Path.of(text("file","")),Path.of(text("runDirectory","")),text("name","Minecraft 地图"));
                default->throw new IOException("未知操作："+command);
            };
            result(output);System.exit(0);
        }catch(Throwable e){Throwable cause=e;while(cause.getCause()!=null)cause=cause.getCause();String message=cause.getMessage();if(message==null||message.isBlank())message=cause.getClass().getSimpleName();message=message.replaceAll("(?i)(access_token|refresh_token|authorization|client_secret)([\\s:=]+)[^\\s,}]+","$1$2[redacted]");emit(Map.of("event","error","message",message.substring(0,Math.min(800,message.length()))));e.printStackTrace(System.err);System.exit(1);}
    }
    private static synchronized void emit(Map<String,?> object){protocol.println(JsonUtils.UGLY_GSON.toJson(object));}
    private static void result(Map<String,?> object){emit(Map.of("event","result","data",object));}
    private static String text(String key,String fallback){return request.has(key)&&!request.get(key).isJsonNull()?request.get(key).getAsString():fallback;}
    private static int integer(String key,int fallback){return request.has(key)?request.get(key).getAsInt():fallback;}
    private static void stage(String message){emit(Map.of("event","progress","message",message));}
    private static void perform(Task<?> task)throws Exception{
        TaskExecutor executor=task.executor();
        executor.addTaskListener(new TaskListener(){
            @Override public void onRunning(Task<?> t){String simple=t.getClass().getSimpleName();String label=simple.contains("Asset")?"下载游戏资源":simple.contains("Library")?"检查运行依赖":simple.contains("Modpack")?"处理整合包":simple.contains("JavaDownload")?"下载 Java 运行时":"";long now=System.currentTimeMillis();if(!label.isEmpty()&&now-lastProgress.get()>700 && lastProgress.getAndSet(now)<now-700)stage(label);}
            @Override public void onPropertiesUpdate(Task<?> t){double value=t.progressProperty().get();long now=System.currentTimeMillis();if(t==task&&value>=0&&now-lastProgress.get()>200){lastProgress.set(now);emit(Map.of("event","progress","progress",value));}}
        });
        Runtime.getRuntime().addShutdownHook(new Thread(executor::cancel));
        if(!executor.test()){Exception error=executor.getException();if(error!=null)throw error;throw new IOException("任务未完成");}
    }
    private static String validName(String name)throws IOException{if(name.isBlank()||name.equals(".")||name.equals("..")||name.contains("/")||name.contains("\\"))throw new IOException("无效的实例名称");return name;}
    private static Map<String,Object> mods()throws Exception{
        String id=validName(text("id",""));var manager=repository.getModManager(id);manager.refresh();List<Map<String,Object>> list=new ArrayList<>();
        for(var mod:manager.getLocalFiles()){Map<String,Object> item=new LinkedHashMap<>();item.put("path",mod.getFile().toString());item.put("name",Objects.toString(mod.getName(),mod.getFileName()));item.put("version",Objects.toString(mod.getVersion(),""));item.put("authors",Objects.toString(mod.getAuthors(),""));item.put("modId",Objects.toString(mod.getId(),""));item.put("enabled",mod.isActive());item.put("size",Files.size(mod.getFile()));item.put("loader",mod.getModLoaderType().name());item.put("iconPath",NativeResourceFiles.icon(mod.getFile(),mod.getLogoPath(),data));item.put("website",mod.getUrl());list.add(item);}
        return Map.of("mods",list);
    }
    @SuppressWarnings("unchecked") private static Map<String,Object> resources()throws Exception{
        Path run=Path.of(text("runDirectory",""));List<Map<String,Object>> items=new ArrayList<>();String id=validName(text("id",""));var manager=repository.getModManager(id);manager.refresh();
        for(var mod:manager.getLocalFiles())items.add(NativeResourceFiles.item(mod.getFile(),"mods",Objects.toString(mod.getName(),mod.getFileName()),mod.getLogoPath(),mod.getUrl(),data));
        for(String kind:List.of("resourcepacks","shaderpacks","saves")){Path folder=run.resolve(kind);if(!Files.isDirectory(folder))continue;try(var paths=Files.list(folder)){for(Path file:paths.filter(p->!p.getFileName().toString().startsWith(".")&&!Files.isSymbolicLink(p)).sorted().toList()){if(Files.isDirectory(file)||file.getFileName().toString().matches(".*\\.(zip|disabled)"))items.add(NativeResourceFiles.item(file,kind,file.getFileName().toString(),kind.equals("saves")?"icon.png":null,null,data));}}}
        return NativeResourceFiles.index(items,run,data,request.has("resolve")&&request.get("resolve").getAsBoolean());
    }
    @SuppressWarnings("unchecked") private static Map<String,Object> languageScan()throws Exception{
        String id=validName(text("id",""));
        try{
            request.addProperty("clientJar",repository.getVersionJar(id).toString());
            var version=repository.getVersion(id).resolve(repository);var index=version.getAssetIndex();
            if(index!=null){JsonObject languages=new JsonObject();for(var object:repository.getAssetIndex(id,index.getId()).getObjects().entrySet()){
                String name=object.getKey();String relative=name.startsWith("minecraft/lang/")?"assets/"+name:name.startsWith("lang/")?"assets/minecraft/"+name:"";
                if(!NativeResourceFiles.language(relative))continue;Path file=repository.getAssetObject(id,index.getId(),object.getValue());if(Files.isRegularFile(file))languages.addProperty(relative,file.toString());
            }request.add("minecraftLanguages",languages);}
        }catch(Exception ignored){}
        return new NativeLocalization(request,data).scan((List<Map<String,Object>>)resources().get("resources"));
    }
    private static Map<String,Object> loaders()throws Exception{
        String game=text("version","");VersionList<?> list=provider.getVersionListById(text("loader","fabric"));perform(list.refreshAsync(game));
        List<String> versions=list.getVersions(game).stream().map(RemoteVersion::getSelfVersion).distinct().sorted((a,b)->VersionNumber.compare(b,a)).toList();return Map.of("versions",versions);
    }
    private static Map<String,Object> install()throws Exception{
        String name=validName(text("name",""));if(Files.exists(repository.getVersionRoot(name)))throw new IOException("该实例目录已存在，未覆盖");
        GameBuilder builder=dependency.gameBuilder().name(name).gameVersion(text("version",""));String loader=text("loader","vanilla");if(!loader.equals("vanilla"))builder.version(loader,text("loaderVersion",""));
        stage("准备下载");perform(builder.buildAsync());repository.refreshVersions();persistIsolation(name);return Map.of("id",name);
    }
    private static void persistIsolation(String id)throws IOException{Path config=repository.getVersionRoot(id).resolve(".hmcl/config/instance-game-settings.json");Files.createDirectories(config.getParent());if(!Files.exists(config)){Files.writeString(config,"{\"$schema\":\"https://schemas.glavo.site/hmcl/instance-game-settings/1.0.0\",\"overrideProperties\":[\"runningDirectory\"]}");}}
    private static Map<String,Object> repair()throws Exception{String id=validName(text("id",""));stage("校验文件");perform(dependency.checkGameCompletionAsync(repository.getVersion(id),true));return Map.of("id",id);}
    private static JavaRuntime readJava(Path binary)throws IOException{Path release=binary.getParent().getParent().resolve("release");JavaInfo info;try(BufferedReader reader=Files.newBufferedReader(release)){info=JavaInfo.fromReleaseFile(reader);}catch(IOException|RuntimeException e){info=JavaInfoUtils.fromExecutable(binary);}return JavaRuntime.of(binary,info,false);}
    private static JavaRuntime compatibleJava(GameJavaVersion required)throws Exception{
        if(required==null)required=GameJavaVersion.JAVA_8;
        if(request.has("javaExplicit")&&request.get("javaExplicit").getAsBoolean()){JavaRuntime selected=readJava(Path.of(text("gameJava","")));if(selected.getParsedVersion()<required.majorVersion())throw new IOException("所选 Java 版本过低，此实例需要 Java "+required.majorVersion());return selected;}
        List<Path> candidates=new ArrayList<>();candidates.add(Path.of(text("gameJava",System.getProperty("java.home")+"/bin/java")));candidates.add(Path.of(System.getProperty("java.home"),"bin/java"));
        Process finder=new ProcessBuilder("/usr/libexec/java_home","-v",Integer.toString(required.majorVersion())).redirectError(ProcessBuilder.Redirect.DISCARD).start();String home=new String(finder.getInputStream().readAllBytes(),StandardCharsets.UTF_8).strip();if(finder.waitFor()==0&&!home.isBlank())candidates.add(Path.of(home,"bin/java"));
        HMCLJavaRepository originalRuntimes=new HMCLJavaRepository(Path.of(System.getProperty("user.home"),"Library/Application Support/HMCL/java"));Path originalCached=originalRuntimes.getJavaExecutable(Platform.SYSTEM_PLATFORM,required);if(originalCached!=null)candidates.add(0,originalCached);
        HMCLJavaRepository runtimes=new HMCLJavaRepository(data.resolve("java"));Path cached=runtimes.getJavaExecutable(Platform.SYSTEM_PLATFORM,required);if(cached!=null)candidates.add(0,cached);
        for(Path binary:candidates){try{JavaRuntime java=readJava(binary);if(java.getParsedVersion()==required.majorVersion())return java;}catch(IOException ignored){}}
        if(Files.getFileStore(data).getUsableSpace()<400*1024*1024L)throw new IOException("下载 Java 运行时需要至少 400 MB 可用空间。");
        stage("准备 Java "+required.majorVersion());Task<JavaRuntime> download=runtimes.getDownloadJavaTask(provider,Platform.SYSTEM_PLATFORM,required);perform(download);return download.getResult();
    }
    private static JavaRuntime gameJava(Version version)throws Exception{
        GameJavaVersion required=version.getJavaVersion()!=null?version.getJavaVersion():GameJavaVersion.getMinimumJavaVersion(org.jackhuang.hmcl.util.versioning.GameVersionNumber.asGameVersion(repository.getGameVersion(version).orElse("1.20.1")));
        return compatibleJava(required);
    }
    private static Map<String,Object> launch()throws Exception{
        if(request.has("completeDependencies")&&request.get("completeDependencies").getAsBoolean()){
            Map<String,Object> completed=new NativeDependencies(request,data,provider,NativeBridge::stage).complete();
            emit(Map.of("event","dependenciesCompleted","data",completed));
        }
        String id=validName(text("id",""));Version original=repository.getVersion(id);Version version=original.resolve(repository);stage("检查依赖");perform(dependency.checkGameCompletionAsync(original,false));
        AuthInfo authentication;
        if(request.has("account")){JsonObject stored=request.getAsJsonObject("account");Account account=restore(text("accountType","offline"),stored.getAsJsonObject("hmclMetadata"),stored.getAsJsonObject("privateData"));authentication=account.logIn();emit(Map.of("event","accountUpdated","data",serialize(account,text("accountType","offline"))));}
        else{String name=text("username","");if(!name.matches("[A-Za-z0-9_]{3,16}"))throw new IOException("离线用户名无效");UUID uuid;try{uuid=UUID.fromString(text("uuid",""));}catch(IllegalArgumentException e){uuid=UUID.nameUUIDFromBytes(("OfflinePlayer:"+name).getBytes(StandardCharsets.UTF_8));}authentication=new AuthInfo(name,uuid,"0",AuthInfo.USER_TYPE_LEGACY,"{}");}
        JavaRuntime java=gameJava(version);LaunchOptions options=new LaunchOptions.Builder().setGameDir(repository.getRunDirectory(id)).setJava(java).setVersionName(id).setVersionType("MC Harbor").setProfileName(id).setMaxMemory(Math.max(1024,Math.min(6144,integer("memory",3072)))).setWidth(Math.max(640,Math.min(7680,integer("width",1280)))).setHeight(Math.max(480,Math.min(4320,integer("height",800)))).setFullscreen(request.has("fullscreen")&&request.get("fullscreen").getAsBoolean()).setJavaArguments(StringUtils.tokenize(text("jvmArguments",""))).setDaemon(true).setAllowAutoAgent(true).create();
        Files.createDirectories(data.resolve("logs"));PrintWriter gameLog=new PrintWriter(Files.newBufferedWriter(data.resolve("logs").resolve("game-"+System.currentTimeMillis()+".log"),StandardCharsets.UTF_8));
        ProcessListener listener=new ProcessListener(){@Override public synchronized void onLog(String line,boolean error){gameLog.println(line);gameLog.flush();}@Override public void onExit(int code,ExitType type){gameLog.close();}};
        stage("启动游戏");ManagedProcess process=new DefaultLauncher(repository,version,authentication,options,listener,true).launch();emit(Map.of("event","launched","pid",process.getProcess().pid()));int exit=process.getProcess().waitFor();return Map.of("id",id,"exitCode",exit);
    }
    private static Map<String,Object> importPack()throws Exception{
        String name=validName(text("name",""));if(Files.exists(repository.getVersionRoot(name)))throw new IOException("实例目录已存在，未覆盖");Path file=Path.of(text("file",""));
        Modpack pack=ModpackHelper.readModpackManifest(file,StandardCharsets.UTF_8);perform(pack.getInstallTask(dependency,file,name,null));persistIsolation(name);return Map.of("id",name);
    }
    private static Map<String,Object> exportPack()throws Exception{
        String id=validName(text("id",""));String game=repository.getGameVersion(id).orElseThrow(()->new IOException("无法读取 Minecraft 版本"));
        Path output=text("output","").isBlank()?data.resolve("exports/"+id+"-"+System.currentTimeMillis()+".zip"):Path.of(text("output","")).toAbsolutePath().normalize();
        if(Files.exists(output))throw new IOException("导出文件已存在，未覆盖");Files.createDirectories(output.getParent());
        if(output.startsWith(repository.getRunDirectory(id)))throw new IOException("请选择实例目录以外的导出位置。");
        Path temporary=Files.createTempFile(output.getParent(),".harbor-export-",".partial");
        MultiMCInstanceConfiguration configuration=new MultiMCInstanceConfiguration("OneSix",id,game,128,"","","","","","",false,1280,800,integer("memory",3072),512,false,true,false,true,false,false,false,false,false,"default");
        try{stage("导出 MultiMC 整合包");perform(new MultiMCModpackExportTask(repository,id,List.of(),configuration,temporary));verifyArchive(temporary);Files.move(temporary,output);return Map.of("path",output.toString(),"format","MultiMC");}finally{Files.deleteIfExists(temporary);}
    }
    private static void verifyArchive(Path file)throws IOException{try(ZipFile zip=new ZipFile(file.toFile())){byte[] buffer=new byte[65536];for(var entries=zip.entries();entries.hasMoreElements();){ZipEntry entry=entries.nextElement();CRC32 crc=new CRC32();try(InputStream stream=zip.getInputStream(entry)){int count;while((count=stream.read(buffer))>=0)crc.update(buffer,0,count);}if(crc.getValue()!=entry.getCrc())throw new IOException("归档校验失败");}}}
    private record FileStamp(long size,long modified,Object key) {}
    private static Map<Path,FileStamp> backupFiles(Path root,String world)throws IOException {
        Path saves=world.isBlank()?root.resolve("saves"):root.resolve("saves").resolve(validName(world));
        if(!Files.isDirectory(saves,LinkOption.NOFOLLOW_LINKS))throw new IOException("当前实例还没有可备份的存档");
        Map<Path,FileStamp> files=new TreeMap<>();
        try(var walk=Files.walk(saves)){for(Path path:walk.filter(p->Files.isRegularFile(p,LinkOption.NOFOLLOW_LINKS)).filter(p->!p.getFileName().toString().equals("session.lock")).toList()){var attr=Files.readAttributes(path,java.nio.file.attribute.BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS);files.put(path,new FileStamp(attr.size(),attr.lastModifiedTime().toMillis(),attr.fileKey()));}}
        for(String name:List.of("options.txt","optionsof.txt","servers.dat")){Path path=root.resolve(name);if(Files.isRegularFile(path,LinkOption.NOFOLLOW_LINKS)){var attr=Files.readAttributes(path,java.nio.file.attribute.BasicFileAttributes.class);files.put(path,new FileStamp(attr.size(),attr.lastModifiedTime().toMillis(),attr.fileKey()));}}
        return files;
    }
    private static Map<String,Object> backup(boolean unused)throws Exception{
        if(text("runDirectory","").isBlank())throw new IOException("缺少游戏目录");
        Path root=Path.of(text("runDirectory","")).toAbsolutePath().normalize();String world=text("world","");Map<Path,FileStamp> files=backupFiles(root,world);if(files.isEmpty())throw new IOException("没有可备份文件");
        long size=files.values().stream().mapToLong(FileStamp::size).sum();Path directory=data.resolve("backups");Files.createDirectories(directory);if(Files.getFileStore(directory).getUsableSpace()<size+128*1024*1024L)throw new IOException("可用磁盘空间不足");
        List<java.nio.channels.FileChannel> channels=new ArrayList<>();List<java.nio.channels.FileLock> locks=new ArrayList<>();Path temporary=Files.createTempFile(directory,"archive-",".partial");Path output=directory.resolve("Worlds-"+System.currentTimeMillis()+".zip");
        try{
            Set<Path> worlds=new HashSet<>();for(Path file:files.keySet()){Path relative=root.resolve("saves").relativize(file);if(!relative.startsWith("..")&&relative.getNameCount()>1)worlds.add(root.resolve("saves").resolve(relative.getName(0)));}
            for(Path folder:worlds){Path lockFile=folder.resolve("session.lock");if(Files.isRegularFile(lockFile)){var channel=java.nio.channels.FileChannel.open(lockFile,StandardOpenOption.READ,StandardOpenOption.WRITE);channels.add(channel);var lock=channel.tryLock();if(lock==null)throw new IOException("存档正在运行，请退出游戏后备份");locks.add(lock);}}
            stage("备份存档");try(ZipOutputStream zip=new ZipOutputStream(new BufferedOutputStream(Files.newOutputStream(temporary)))){zip.setLevel(3);for(Path path:files.keySet()){zip.putNextEntry(new ZipEntry(root.relativize(path).toString()));Files.copy(path,zip);zip.closeEntry();}}
            if(!files.equals(backupFiles(root,world)))throw new IOException("存档文件正在变化，请退出游戏后重试");verifyArchive(temporary);
            try{Files.move(temporary,output,StandardCopyOption.ATOMIC_MOVE);}catch(AtomicMoveNotSupportedException e){Files.move(temporary,output);}
            return Map.of("path",output.toString(),"files",files.size());
        }finally{for(var lock:locks)lock.close();for(var channel:channels)channel.close();Files.deleteIfExists(temporary);}
    }
    private static MicrosoftService service(){return new MicrosoftService(new OAuth.Callback(){
        @Override public OAuth.Session startServer()throws IOException{throw new IOException("使用设备验证码登录");}
        @Override public void grantDeviceCode(String code,String url){emit(Map.of("event","device","deviceCode",code,"url",url));}
        @Override public void loginCompletedDeviceCode(){}
        @Override public void openBrowser(OAuth.GrantFlow flow,String url){}
        @Override public String getClientId(){return text("clientID","").isBlank()?JarUtils.getAttribute("hmcl.microsoft.auth.id",""):text("clientID","");}
    });}
    private static AuthlibInjectorArtifactProvider injector()throws IOException{
        String version=JarUtils.getAttribute("hmcl.authlib-injector.version","");if(version.isBlank())throw new IOException("缺少认证组件版本");String name="authlib-injector-"+version+".jar";Path file=data.resolve("dependencies").resolve(name);Files.createDirectories(file.getParent());
        if(!Files.isRegularFile(file)){try(InputStream stream=NativeBridge.class.getResourceAsStream("/assets/"+name)){if(stream==null)throw new IOException("缺少认证组件");Files.copy(stream,file);}}
        return new SimpleAuthlibInjectorArtifactProvider(file);
    }
    private static Account restore(String type,JsonObject metadata,JsonObject privateData)throws IOException{
        return switch(type){case "microsoft"->new MicrosoftAccountFactory(service()).fromStorage(metadata,privateData);case "authlibInjector"->new AuthlibInjectorAccountFactory(injector(),AuthlibInjectorServer::new).fromStorage(metadata,privateData);case "offline"->new OfflineAccountFactory(injector()).fromStorage(metadata,privateData);default->throw new IOException("不支持的账号类型："+type);};
    }
    private static Map<String,Object> serialize(Account account,String type){JsonObject meta=new JsonObject(),privateData=new JsonObject();account.writeMetadata(meta);account.writePrivateData(privateData);return Map.of("metadata",Map.of("name",account.getProfileName(),"uuid",account.getProfileID().toString(),"kind",type,"id",account.getAccountID().toString()),"hmclMetadata",meta,"privateData",privateData);}
    private static Map<String,Object> login()throws Exception{MicrosoftAccountFactory factory=new MicrosoftAccountFactory(service());MicrosoftAccount account=factory.create(null,null,null,null,OAuth.GrantFlow.DEVICE);account.logIn();return serialize(account,"microsoft");}
    private static Map<String,Object> migrate()throws Exception{
        Path home=Path.of(System.getProperty("user.home"));Path shared=home.resolve("Library/Application Support/HMCL");Path local=Path.of(text("root","/Applications/.minecraft")).getParent().resolve(".hmcl");
        List<Map<String,Object>> results=new ArrayList<>();Set<String> seen=new HashSet<>();List<String> failures=new ArrayList<>();
        List<Path> bases=List.of(shared,local);List<String> metadataNames=List.of("config/user-accounts.json","config/accounts.json");List<String> secretNames=List.of("private/user-account-private-data.json","private/account-private-data.json");
        Map<String,JsonObject> privateData=new LinkedHashMap<>();for(int i=0;i<bases.size();i++)privateData.putAll(NativeAccountMigration.readPrivateData(bases.get(i).resolve(secretNames.get(i))));
        for(int i=0;i<bases.size();i++){Path metadataFile=bases.get(i).resolve(metadataNames.get(i));if(!Files.isRegularFile(metadataFile))continue;JsonObject container=JsonParser.parseString(Files.readString(metadataFile)).getAsJsonObject();JsonArray records=container.getAsJsonArray("accounts");if(records==null)continue;
            for(JsonElement record:records){JsonObject meta=record.getAsJsonObject();String id=meta.get("accountID").getAsString();if(!seen.add(id))continue;String type=meta.get("type").getAsString();try{JsonObject secret=privateData.getOrDefault(id,new JsonObject());Account account=restore(type,meta,secret);results.add(serialize(account,type));}catch(Exception e){failures.add(type+"："+e.getClass().getSimpleName()+" "+Arrays.stream(e.getStackTrace()).limit(5).map(StackTraceElement::toString).toList());}}
        }
        return Map.of("accounts",results,"failures",failures,"metadataFiles",bases.size());
    }
    private static Map<String,Object> diagnostics(){StringBuilder report=new StringBuilder();for(String address:List.of("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json","https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json")){long start=System.nanoTime();HttpURLConnection connection=null;try{connection=(HttpURLConnection)URI.create(address).toURL().openConnection();connection.setConnectTimeout(6000);connection.setReadTimeout(6000);int status=connection.getResponseCode();if(status!=200)throw new IOException("HTTP "+status);byte[] data=connection.getInputStream().readNBytes(8_000_001);JsonObject manifest=JsonParser.parseString(new String(data,StandardCharsets.UTF_8)).getAsJsonObject();report.append("✓ ").append(URI.create(address).getHost()).append("  ").append(manifest.getAsJsonArray("versions").size()).append(" 个版本  ").append((System.nanoTime()-start)/1_000_000).append(" ms\n");}catch(Exception e){report.append("× ").append(URI.create(address).getHost()).append("  ").append(e.getClass().getSimpleName()).append('\n');}finally{if(connection!=null)connection.disconnect();}}return Map.of("report",report.toString());}
    private static final class Repository extends DefaultGameRepository{
        private final String run;
        Repository(Path root,String run){super(root);this.run=run;}
        @Override public Path getRunDirectory(String id){return run.isBlank()?getVersionRoot(id):Path.of(run);}
    }
}
