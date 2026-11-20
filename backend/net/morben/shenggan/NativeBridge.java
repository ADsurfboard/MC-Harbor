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
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.zip.*;

/** JSON-line adapter for the unmodified, stable HMCL game engine; no JavaFX window is created. */
public final class NativeBridge {
    static String validServer(String value){
        if(value.length()>260 || value.isBlank() || value.chars().anyMatch(c->Character.isWhitespace(c)||Character.isISOControl(c)) || value.matches(".*[/@?#].*")) throw new IllegalArgumentException("Invalid Minecraft server address");
        org.jackhuang.hmcl.util.ServerAddress address=org.jackhuang.hmcl.util.ServerAddress.parse(value);
        if(address.host().isBlank() || address.port()==0 || !address.host().matches(address.host().contains(":")?"[0-9a-fA-F:.]+":"[A-Za-z0-9][A-Za-z0-9.-]*"))throw new IllegalArgumentException("Invalid Minecraft server address");
        return value;
    }
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
            if(command.equals("platformInfo")){
                result(Map.of("javaArchitecture",System.getProperty("os.arch"),"javaVersion",System.getProperty("java.version"),
                    "currentPlatform",Platform.CURRENT_PLATFORM.toString(),"systemPlatform",Platform.SYSTEM_PLATFORM.toString(),
                    "gamePlatform",gameRuntimePlatform().toString(),"javaFxModules",ModuleLayer.boot().findModule("javafx.controls").isPresent()));
                System.exit(0);
            }
            if(command.equals("login")){result(login());System.exit(0);}
            if (command.equals("offlineAccount")) {
                String name = text("username", "");
                if (!name.matches("[A-Za-z0-9_]{3,16}")) throw new IOException("离线用户名无效");
                UUID player = UUID.nameUUIDFromBytes(("OfflinePlayer:" + name).getBytes(StandardCharsets.UTF_8));
                result(serialize(new OfflineAccountFactory(injector()).create(name, player), "offline"));
                System.exit(0);
            }
            if(command.equals("externalLogin")){result(externalLogin());System.exit(0);}
            if(command.equals("migrate")){result(migrate());System.exit(0);}
            if(command.equals("diagnostics")){result(diagnostics());System.exit(0);}
            if (command.equals("inspectJava")) {
                Path binary = Path.of(text("gameJava", "")).toAbsolutePath().normalize();
                if (!Files.isRegularFile(binary)) throw new IOException("找不到所选 Java。");
                JavaRuntime inspected = readJava(binary);
                result(Map.of("version", inspected.getVersion(), "compatibleArchitecture", javaArchitectureMatches(inspected)));
                System.exit(0);
            }
            if(command.equals("worldRead")||command.equals("worldSave")){NativeWorldEditor editor=new NativeWorldEditor(request,data);result(command.equals("worldRead")?editor.read():editor.save());System.exit(0);}
            if(command.equals("profile")||command.equals("applySkin")){
                JsonObject stored=request.getAsJsonObject("account");String type=text("accountType","offline");Account account=restore(type,stored.getAsJsonObject("hmclMetadata"),stored.getAsJsonObject("privateData"));
                Map<String,Object> profile=command.equals("applySkin")?NativeProfiles.apply(account,Path.of(text("skinFile","")),request.has("slim")&&request.get("slim").getAsBoolean(),data):NativeProfiles.describe(account,data,request.has("refresh")&&request.get("refresh").getAsBoolean());
                emit(Map.of("event","accountUpdated","data",serialize(account,type)));result(profile);System.exit(0);
            }
            if(command.equals("downloadCandidates")){
                URI address=URI.create(text("url",""));if(!"https".equalsIgnoreCase(address.getScheme())||address.getHost()==null)throw new IOException("下载地址必须使用 HTTPS");
                DownloadProvider original=new MojangDownloadProvider(),domestic=new BMCLAPIDownloadProvider("https://bmclapi2.bangbang93.com");
                DownloadProvider selected=text("source","auto").equals("official")?new AutoDownloadProvider(original,domestic):new AutoDownloadProvider(domestic,original);
                List<String> candidates=new ArrayList<>(selected.injectURLWithCandidates(address.toString()).stream().map(URI::toString).distinct().toList());if(!text("source","auto").equals("official")&&Set.of("cdn.modrinth.com","edge.forgecdn.net").contains(address.getHost())){String domesticFile=address.toString().replace("https://"+address.getHost(),"https://mod.mcimirror.top");candidates.remove(domesticFile);candidates.add(0,domesticFile);}result(Map.of("urls",candidates));System.exit(0);
            }
            Path root=Path.of(text("root",defaultMinecraftDirectory().toString())).toAbsolutePath().normalize();
            repository=new Repository(root,text("runDirectory",""));repository.refreshVersions();
            DownloadProvider official=new MojangDownloadProvider(),mirror=new BMCLAPIDownloadProvider("https://bmclapi2.bangbang93.com");
            provider=text("source","auto").equals("official")?new AutoDownloadProvider(official,mirror):new AutoDownloadProvider(mirror,official);
            FetchTask.setDownloadExecutorConcurrency(Math.max(4,Math.min(24,integer("threads",8))));
            dependency=new DefaultDependencyManager(repository,provider,new DefaultCacheRepository(root));
            Map<String,Object> output=switch(command){
                case "mods"->mods();case "resources"->resources();case "loaders"->loaders();case "gameVersions"->gameVersions();case "install"->install();case "repair"->repair();
                case "langScan"->languageScan();case "langOpen"->new NativeLocalization(request,data).open();case "langRead"->new NativeLocalization(request,data).read();case "langSave"->new NativeLocalization(request,data).save();
                case "langPending"->new NativeLocalization(request,data).pending();case "langTranslate"->new NativeLocalization(request,data).translate();case "langImport"->new NativeLocalization(request,data).importTranslations();case "langExport"->new NativeLocalization(request,data).export();case "langApply"->new NativeLocalization(request,data).applyTextAssets();
                case "launch"->launch();case "import"->importPack();case "backup"->backup(false);case "export"->exportPack();
                case "dependencyScan"->new NativeDependencies(request,data,provider,NativeBridge::stage).scan();
                case "dependencyComplete"->new NativeDependencies(request,data,provider,NativeBridge::stage).complete();
                case "runtime"->Map.of("path",compatibleJava(GameJavaVersion.get(integer("major",25))).getBinary().toString());
                case "cfSearch"->new NativeResources(request,provider).search();case "cfVersions"->new NativeResources(request,provider).versions();case "cfPlan"->new NativeResources(request,provider).plan();
                case "installWorld"->NativeWorldImport.install(Path.of(text("file","")),Path.of(text("runDirectory","")),text("name","Minecraft 地图"));
                default->throw new IOException("未知操作："+command);
            };
            result(output);System.exit(0);
        }catch(Throwable e){Throwable cause=e;while(cause.getCause()!=null)cause=cause.getCause();String message=cause.getMessage();if(message==null||message.isBlank())message=cause.getClass().getSimpleName();message=message.replaceAll("(?i)(access_token|refresh_token|authorization|client_secret)([\\s:=]+)[^\\s,}]+","$1$2[redacted]");if(request!=null&&request.has("password")){String secret=text("password","");if(!secret.isEmpty())message=message.replace(secret,"[redacted]");}emit(Map.of("event","error","message",message.substring(0,Math.min(800,message.length()))));e.printStackTrace(System.err);System.exit(1);}
    }
    private static synchronized void emit(Map<String,?> object){protocol.println(JsonUtils.UGLY_GSON.toJson(object));}
    private static void result(Map<String,?> object){emit(Map.of("event","result","data",object));}
    private static String text(String key,String fallback){return request.has(key)&&!request.get(key).isJsonNull()?request.get(key).getAsString():fallback;}
    private static int integer(String key,int fallback){return request.has(key)?request.get(key).getAsInt():fallback;}
    private static void stage(String message){emit(Map.of("event","progress","message",message));}
    private static void perform(Task<?> task)throws Exception{
        TaskExecutor executor=task.executor();java.util.concurrent.atomic.AtomicInteger completed=new java.util.concurrent.atomic.AtomicInteger();
        executor.addTaskListener(new TaskListener(){
            @Override public void onRunning(Task<?> t){String simple=t.getClass().getSimpleName();String label=simple.contains("Asset")?"下载游戏资源":simple.contains("Library")?"检查运行依赖":simple.contains("Modpack")?"处理整合包":simple.contains("JavaDownload")?"下载 Java 运行时":"";long now=System.currentTimeMillis();if(!label.isEmpty()&&now-lastProgress.get()>700 && lastProgress.getAndSet(now)<now-700)stage(label);}
            @Override public void onFinished(Task<?> t){int count=completed.incrementAndGet();if(text("command","").equals("import") && count%8==0)stage("2 / 4 · 正在处理整合包，已完成 "+count+" 项文件与依赖任务");}
            @Override public void onPropertiesUpdate(Task<?> t){double value=t.progressProperty().get();long now=System.currentTimeMillis();if(t==task&&value>=0&&now-lastProgress.get()>200){lastProgress.set(now);emit(Map.of("event","progress","progress",value));}}
        });
        Runtime.getRuntime().addShutdownHook(new Thread(executor::cancel));
        if(!executor.test()){Exception error=executor.getException();if(error!=null)throw error;throw new IOException("任务未完成");}
    }
    private static String validName(String name)throws IOException{
        if(name.isBlank()||name.length()>100||name.equals(".")||name.equals("..")||!name.equals(name.strip())||name.endsWith(".")||name.endsWith(" ")
                ||name.chars().anyMatch(c->Character.isISOControl(c)||"<>:\"/\\|?*".indexOf(c)>=0)
                ||name.matches("(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\\..*)?$"))throw new IOException("无效的实例名称");
        return name;
    }
    private static Map<String,Object> mods()throws Exception{
        String id=validName(text("id",""));var manager=repository.getModManager(id);manager.refresh();List<Map<String,Object>> list=new ArrayList<>();
        for(var mod:manager.getLocalFiles()){Map<String,Object> item=new LinkedHashMap<>();item.put("path",mod.getFile().toString());item.put("name",Objects.toString(mod.getName(),mod.getFileName()));item.put("version",Objects.toString(mod.getVersion(),""));item.put("description",mod.getDescription()==null?"":mod.getDescription().toStringSingleLine());item.put("authors",Objects.toString(mod.getAuthors(),""));item.put("modId",Objects.toString(mod.getId(),""));item.put("enabled",mod.isActive());item.put("size",Files.size(mod.getFile()));item.put("loader",mod.getModLoaderType().name());item.put("iconPath",NativeResourceFiles.icon(mod.getFile(),mod.getLogoPath(),data));item.put("website",mod.getUrl());list.add(item);}
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
    private static Map<String,Object> gameVersions()throws Exception{
        VersionList<?> list=provider.getVersionListById("game");perform(list.refreshAsync(""));
        List<Map<String,Object>> versions=list.getVersions("").stream().map(version->Map.<String,Object>of(
                "id",version.getSelfVersion(),"version",version.getGameVersion(),
                "type",version.getVersionType().name().toLowerCase(Locale.ROOT),
                "releaseTime",Objects.toString(version.getReleaseDate(),"")))
                .sorted((a,b)->Objects.toString(b.get("releaseTime"),"").compareTo(Objects.toString(a.get("releaseTime"),""))).toList();
        return Map.of("versions",versions);
    }
    private static Map<String,Object> install()throws Exception{
        String name=validName(text("name",""));if(Files.exists(repository.getVersionRoot(name)))throw new IOException("该实例目录已存在，未覆盖");
        GameBuilder builder=dependency.gameBuilder().name(name).gameVersion(text("version",""));String loader=text("loader","vanilla");if(!loader.equals("vanilla"))builder.version(loader,text("loaderVersion",""));
        stage("准备下载");perform(builder.buildAsync());repository.refreshVersions();persistIsolation(name);return Map.of("id",name);
    }
    private static void persistIsolation(String id)throws IOException{Path config=repository.getVersionRoot(id).resolve(".hmcl/config/instance-game-settings.json");Files.createDirectories(config.getParent());if(!Files.exists(config)){Files.writeString(config,"{\"$schema\":\"https://schemas.glavo.site/hmcl/instance-game-settings/1.0.0\",\"overrideProperties\":[\"runningDirectory\"]}");}}
    private static Map<String,Object> repair()throws Exception{String id=validName(text("id",""));stage("校验文件");perform(dependency.checkGameCompletionAsync(repository.getVersion(id),true));return Map.of("id",id);}
    private static JavaRuntime readJava(Path binary)throws IOException{Path release=binary.getParent().getParent().resolve("release");JavaInfo info;try(BufferedReader reader=Files.newBufferedReader(release)){info=JavaInfo.fromReleaseFile(reader);}catch(IOException|RuntimeException e){info=JavaInfoUtils.fromExecutable(binary);}return JavaRuntime.of(binary,info,false);}
    private static boolean isWindows(){return System.getProperty("os.name","").toLowerCase(Locale.ROOT).startsWith("windows");}
    private static boolean isMacOS(){return System.getProperty("os.name","").toLowerCase(Locale.ROOT).contains("mac");}
    private static Path javaBinary(Path home){return home.resolve("bin").resolve(isWindows()?"java.exe":"java");}
    private static Path defaultMinecraftDirectory(){
        String appData=System.getenv("APPDATA");
        return isWindows()&&appData!=null&&!appData.isBlank()?Path.of(appData,".minecraft"):Path.of(System.getProperty("user.home"),".minecraft");
    }
    private static Path hmclUserHome(){
        String configured=System.getProperty("hmcl.home",System.getenv("HMCL_USER_HOME"));
        if(configured!=null&&!configured.isBlank())return Path.of(configured).toAbsolutePath().normalize();
        if(isWindows()){
            String appData=System.getenv("APPDATA");
            return Path.of(appData==null||appData.isBlank()?System.getProperty("user.home"):appData,".hmcl").toAbsolutePath().normalize();
        }
        if(isMacOS())return Path.of(System.getProperty("user.home"),"Library","Application Support","HMCL").toAbsolutePath().normalize();
        String xdg=System.getenv("XDG_DATA_HOME");
        return xdg!=null&&!xdg.isBlank()?Path.of(xdg,"hmcl").toAbsolutePath().normalize():Path.of(System.getProperty("user.home"),".local","share","hmcl").toAbsolutePath().normalize();
    }
    private static JavaRuntime compatibleJava(GameJavaVersion required)throws Exception{
        if(required==null)required=GameJavaVersion.JAVA_8;
        if(request.has("javaExplicit")&&request.get("javaExplicit").getAsBoolean()){
            String selectedPath=text("gameJava","");if(selectedPath.isBlank())throw new IOException("请先选择此实例使用的 Java。");
            JavaRuntime selected=readJava(Path.of(selectedPath));if(selected.getParsedVersion()!=required.majorVersion())throw new IOException("此实例需要 Java "+required.majorVersion());if(!javaArchitectureMatches(selected))throw new IOException("所选 Java 与游戏运行环境架构不匹配；Windows ARM64 版当前使用 x64 Java 兼容模式启动游戏。");return selected;
        }
        List<Path> candidates=new ArrayList<>();
        String selectedPath=text("gameJava","");if(!selectedPath.isBlank())candidates.add(Path.of(selectedPath));
        candidates.add(javaBinary(Path.of(System.getProperty("java.home"))));
        String javaHome=System.getenv("JAVA_HOME");if(javaHome!=null&&!javaHome.isBlank())candidates.add(javaBinary(Path.of(javaHome)));
        if(isMacOS()){
            Process finder=new ProcessBuilder("/usr/libexec/java_home","-v",Integer.toString(required.majorVersion())).redirectError(ProcessBuilder.Redirect.DISCARD).start();
            String home=new String(finder.getInputStream().readAllBytes(),StandardCharsets.UTF_8).strip();if(finder.waitFor()==0&&!home.isBlank())candidates.add(javaBinary(Path.of(home)));
        }else if(isWindows()){
            String path=System.getenv("PATH");if(path!=null)for(String entry:path.split(java.util.regex.Pattern.quote(File.pathSeparator)))if(!entry.isBlank())candidates.add(Path.of(entry).resolve("java.exe"));
            for(String variable:List.of("ProgramFiles","ProgramFiles(x86)","LOCALAPPDATA")){
                String folder=System.getenv(variable);if(folder==null||folder.isBlank())continue;
                for(String vendor:List.of("Java","Eclipse Adoptium","Microsoft","Zulu")){
                    Path parent=Path.of(folder).resolve(vendor);if(!Files.isDirectory(parent))continue;
                    try(var entries=Files.list(parent)){for(Path entry:entries.filter(Files::isDirectory).limit(40).toList())candidates.add(javaBinary(entry));}
                }
            }
        }
        Platform gamePlatform=gameRuntimePlatform();
        HMCLJavaRepository originalRuntimes=new HMCLJavaRepository(hmclUserHome().resolve("java"));Path originalCached=originalRuntimes.getJavaExecutable(gamePlatform,required);if(originalCached!=null)candidates.add(0,originalCached);
        HMCLJavaRepository runtimes=new HMCLJavaRepository(data.resolve("java"));Path cached=runtimes.getJavaExecutable(gamePlatform,required);if(cached!=null)candidates.add(0,cached);
        Set<Path> checked=new HashSet<>();for(Path binary:candidates){try{Path normalized=binary.toAbsolutePath().normalize();if(!checked.add(normalized)||!Files.isRegularFile(normalized))continue;JavaRuntime java=readJava(normalized);if(java.getParsedVersion()==required.majorVersion() && javaArchitectureMatches(java))return java;}catch(IOException|RuntimeException ignored){}}
        if(Files.getFileStore(data).getUsableSpace()<400*1024*1024L)throw new IOException("下载 Java 运行时需要至少 400 MB 可用空间。");
        stage("准备 Java "+required.majorVersion());Task<JavaRuntime> download=runtimes.getDownloadJavaTask(provider,gamePlatform,required);perform(download);return download.getResult();
    }
    private static JavaRuntime gameJava(Version version)throws Exception{
        GameJavaVersion required=version.getJavaVersion()!=null?version.getJavaVersion():GameJavaVersion.getMinimumJavaVersion(org.jackhuang.hmcl.util.versioning.GameVersionNumber.asGameVersion(repository.getGameVersion(version).orElse("1.20.1")));
        return compatibleJava(required);
    }
    private static boolean javaArchitectureMatches(JavaRuntime java) {
        return !isWindows() || java.getPlatform().equals(Platform.CURRENT_PLATFORM);
    }
    static Platform gameRuntimePlatform() {
        // The chosen game bridge determines native libraries and Java architecture together.
        // On Windows ARM64 the compatibility bridge is an x64 JVM; SYSTEM_PLATFORM remains ARM64.
        return isWindows() ? Platform.CURRENT_PLATFORM : Platform.SYSTEM_PLATFORM;
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
        JavaRuntime java=gameJava(version);LaunchOptions options=new LaunchOptions.Builder().setGameDir(repository.getRunDirectory(id)).setJava(java).setVersionName(id).setVersionType("MC Harbor").setProfileName(id).setMaxMemory(Math.max(1024,Math.min(6144,integer("memory",3072)))).setWidth(Math.max(640,Math.min(7680,integer("width",1280)))).setHeight(Math.max(480,Math.min(4320,integer("height",800)))).setFullscreen(request.has("fullscreen")&&request.get("fullscreen").getAsBoolean()).setJavaArguments(StringUtils.tokenize(text("jvmArguments",""))).setDaemon(true).setAllowAutoAgent(true).setQuickPlayOption(text("serverAddress","").isBlank()?null:new org.jackhuang.hmcl.game.QuickPlayOption.MultiPlayer(validServer(text("serverAddress","")))).create();
        Files.createDirectories(data.resolve("logs"));PrintWriter gameLog=new PrintWriter(Files.newBufferedWriter(data.resolve("logs").resolve("game-"+System.currentTimeMillis()+".log"),StandardCharsets.UTF_8));
        ProcessListener listener=new ProcessListener(){@Override public synchronized void onLog(String line,boolean error){gameLog.println(line);gameLog.flush();}@Override public void onExit(int code,ExitType type){gameLog.close();}};
        Path stop=NativeGameControl.stopPath(data,text("stopFile",""));
        stage("启动游戏");ManagedProcess process=new DefaultLauncher(repository,version,authentication,options,listener,true).launch();emit(Map.of("event","launched","pid",process.getProcess().pid()));NativePlayHistory history=null;try{if(request.has("historySessionID"))history=new NativePlayHistory(data,text("historySessionID",""),repository.getRunDirectory(id),process.getProcess().pid());}catch(Exception error){System.err.println("Playtime receipt unavailable");}int exit;try{exit=NativeGameControl.waitFor(process.getProcess(),stop);}finally{if(history!=null)history.close();}return Map.of("id",id,"exitCode",exit);
    }
    private static Map<String,Object> importPack()throws Exception{
        String name=validName(text("name",""));if(Files.exists(repository.getVersionRoot(name)))throw new IOException("实例目录已存在，未覆盖");Path file=Path.of(text("file",""));
        stage("1 / 4 · 读取整合包清单："+file.getFileName());verifyArchive(file);
        Modpack pack=ModpackHelper.readModpackManifest(file,StandardCharsets.UTF_8);stage("2 / 4 · 解压实例与配置，准备下载缺失资源");perform(pack.getInstallTask(dependency,file,name,null));stage("3 / 4 · 写入独立游戏目录与实例配置");persistIsolation(name);stage("4 / 4 · 导入完成："+name);return Map.of("id",name);
    }
    private static Map<String,Object> exportPack()throws Exception{
        String id=validName(text("id",""));String game=repository.getGameVersion(id).orElseThrow(()->new IOException("无法读取 Minecraft 版本"));
        Path output=text("output","").isBlank()?data.resolve("exports/"+id+"-"+System.currentTimeMillis()+".zip"):Path.of(text("output","")).toAbsolutePath().normalize();
        if(Files.exists(output))throw new IOException("导出文件已存在，未覆盖");Files.createDirectories(output.getParent());
        if(output.startsWith(repository.getRunDirectory(id)))throw new IOException("请选择实例目录以外的导出位置。");
        Path temporary=Files.createTempFile(output.getParent(),".harbor-export-",".partial");
        MultiMCInstanceConfiguration configuration=new MultiMCInstanceConfiguration("OneSix",id,game,128,"","","","","","",false,1280,800,integer("memory",3072),512,false,true,false,true,false,false,false,false,false,"default");
        try{stage("导出 MultiMC 整合包");perform(new MultiMCModpackExportTask(repository,id,List.of(),configuration,temporary));stage("筛选所选导出内容并校验归档");NativeExport.filter(temporary,request);verifyArchive(temporary);Files.move(temporary,output);return Map.of("path",output.toString(),"format","MultiMC");}finally{Files.deleteIfExists(temporary);}
    }
    private static void verifyArchive(Path file)throws IOException{try(ZipFile zip=new ZipFile(file.toFile())){if(zip.size()>250000)throw new IOException("归档文件条目过多");byte[] buffer=new byte[65536];long total=0;for(var entries=zip.entries();entries.hasMoreElements();){ZipEntry entry=entries.nextElement();if(!NativeResourceFiles.safe(entry.getName()))throw new IOException("归档包含不安全路径");CRC32 crc=new CRC32();try(InputStream stream=zip.getInputStream(entry)){int count;while((count=stream.read(buffer))>=0){total+=count;if(total>100_000_000_000L)throw new IOException("归档展开量过大");crc.update(buffer,0,count);}}if(crc.getValue()!=entry.getCrc())throw new IOException("归档校验失败");}}}
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
            stage("备份存档");try(ZipOutputStream zip=new ZipOutputStream(new BufferedOutputStream(Files.newOutputStream(temporary)))){zip.setLevel(3);for(Path path:files.keySet()){zip.putNextEntry(new ZipEntry(root.relativize(path).toString().replace(File.separatorChar,'/')));Files.copy(path,zip);zip.closeEntry();}}
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
    private static Map<String,Object> externalLogin()throws Exception{
        String address=text("server","").strip(),username=text("username","").strip(),password=text("password","");
        if(!address.contains("://"))address="https://"+address;
        URI uri=URI.create(address);if(!List.of("http","https").contains(uri.getScheme())||uri.getHost()==null||uri.getUserInfo()!=null||uri.getFragment()!=null||uri.getQuery()!=null)throw new IOException("认证服务器地址无效");
        if(username.isBlank()||password.isEmpty())throw new IOException("请输入账号和密码");
        AuthlibInjectorServer server=AuthlibInjectorServer.locateServer(address);
        URI resolved=URI.create(server.getUrl());if(uri.getScheme().equals("https")&&!resolved.getScheme().equals("https"))throw new IOException("认证服务器重定向到不安全的 HTTP 地址");
        List<Map<String,String>> choices=new ArrayList<>();String selected=text("profile","");
        CharacterSelector selector=(service,profiles)->{
            if(profiles.size()==1)return profiles.get(0);
            for(var profile:profiles){choices.add(Map.of("id",profile.getId().toString(),"name",profile.getName()));if(profile.getId().toString().equalsIgnoreCase(selected))return profile;}
            throw new NoSelectedCharacterException();
        };
        try{AuthlibInjectorAccount account=new AuthlibInjectorAccountFactory(injector(),AuthlibInjectorServer::new).create(selector,username,password,null,server);return serialize(account,"authlibInjector");}
        catch(NoSelectedCharacterException e){if(!choices.isEmpty())return Map.of("profiles",choices);throw e;}
    }
    private record MigrationFile(Path file, Path secret, boolean userStorage) {}

    private static void addRoot(Set<Path> roots, Path path) {
        if (path != null) roots.add(path.toAbsolutePath().normalize());
    }

    private static List<MigrationFile> migrationFiles() {
        Set<Path> roots = new LinkedHashSet<>();
        Map<Path, MigrationFile> files = new LinkedHashMap<>();
        for (Path selected : migrationPaths("migrationFiles")) {
            addMigrationFile(files, selected);
        }
        for (Path selected : migrationPaths("migrationRoots")) {
            addRoot(roots, selected);
            addRoot(roots, selected.resolve(".hmcl"));
            if (selected.getFileName() != null && selected.getFileName().toString().equalsIgnoreCase("config"))
                addRoot(roots, selected.getParent());
        }
        if (roots.isEmpty() && files.isEmpty() && !request.has("migrationFiles") && !request.has("migrationRoots")) {
            addRoot(roots, hmclUserHome());
            String local = System.getenv("HMCL_LOCAL_HOME");
            if (local != null && !local.isBlank()) addRoot(roots, Path.of(local));
            Path gameRoot = Path.of(text("root", defaultMinecraftDirectory().toString())).toAbsolutePath().normalize();
            addRoot(roots, gameRoot.resolve(".hmcl"));
            addRoot(roots, gameRoot);
            if (gameRoot.getParent() != null) {
                addRoot(roots, gameRoot.getParent().resolve(".hmcl"));
                addRoot(roots, gameRoot.getParent());
            }
            addRoot(roots, Path.of(System.getProperty("user.dir", ".")));
        }
        for (Path root : roots) {
            for (String name : List.of("config/user-accounts.json", "config/accounts.json",
                    "user-accounts.json", "accounts.json", "hmcl.json"))
                addMigrationFile(files, root.resolve(name));
        }
        return files.values().stream().sorted(Comparator.comparing(file -> file.secret() == null)).toList();
    }

    private static List<Path> migrationPaths(String key) {
        if (!request.has(key) || !request.get(key).isJsonArray()) return List.of();
        List<Path> entries = new ArrayList<>();
        for (JsonElement item : request.getAsJsonArray(key)) {
            if (item.isJsonPrimitive() && item.getAsJsonPrimitive().isString()) {
                try { entries.add(Path.of(item.getAsString()).toAbsolutePath().normalize()); }
                catch (InvalidPathException ignored) {}
            }
        }
        return entries;
    }

    private static void addMigrationFile(Map<Path, MigrationFile> files, Path file) {
        if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS) || file.getParent() == null) return;
        String name = file.getFileName().toString().toLowerCase(Locale.ROOT);
        Path parent = file.getParent();
        boolean inConfig = parent.getFileName() != null && parent.getFileName().toString().equalsIgnoreCase("config");
        Path base = inConfig ? parent.getParent() : parent;
        if (base == null) return;
        boolean shared = name.equals("user-accounts.json") || name.equals("accounts.json") && !inConfig;
        Path secret = name.equals("hmcl.json") ? null : base.resolve(shared
                ? "private/user-account-private-data.json" : "private/account-private-data.json");
        files.putIfAbsent(file, new MigrationFile(file, secret, shared));
    }

    private static Map<String,Object> reauthenticationRecord(JsonObject metadata,String id,String type){
        String name=NativeResourceFiles.text(metadata,"profileName",NativeResourceFiles.text(metadata,"loginName","需要重新登录"));
        String uuid=NativeResourceFiles.text(metadata,"profileID","");
        return Map.of("metadata",Map.of("name",name,"uuid",uuid,"kind",type,"id",id),"hmclMetadata",metadata,"privateData",new JsonObject(),"requiresReauth",true);
    }
    private static Map<String,Object> migrate() {
        Map<String, Map<String,Object>> results = new LinkedHashMap<>();
        List<String> failures = new ArrayList<>();
        int metadataFiles = 0;
        for (MigrationFile source : migrationFiles()) {
            try {
                if (Files.size(source.file()) > 16_000_000) throw new IOException("账号文件过大");
                String content = Files.readString(source.file()).replaceFirst("^\\uFEFF", "");
                JsonElement document = JsonParser.parseString(content);
                JsonElement node = document.isJsonObject() ? document.getAsJsonObject().get("accounts") : document;
                if (node == null || !node.isJsonArray()) continue;
                metadataFiles++;
                Map<String, JsonObject> secrets = new HashMap<>();
                if (source.secret() != null) {
                    try { secrets.putAll(NativeAccountMigration.readPrivateData(source.secret())); }
                    catch (IOException | RuntimeException ex) { failures.add("一个 HMCL 私有数据文件无法读取。"); }
                }
                List<JsonObject> rows = new ArrayList<>();
                JsonArray legacy = new JsonArray();
                for (JsonElement record : node.getAsJsonArray()) {
                    if (!record.isJsonObject()) continue;
                    JsonObject row = record.getAsJsonObject();
                    if (row.has("accountID")) rows.add(row);
                    else legacy.add(row);
                }
                if (!legacy.isEmpty()) {
                    try {
                        var converted = NativeAccountMigration.migrateLegacyAccounts(legacy, source.userStorage());
                        rows.addAll(converted.metadata());
                        converted.privateData().forEach(secrets::putIfAbsent);
                        if (converted.metadata().size() < legacy.size()) failures.add("有旧账号记录缺少可迁移的身份信息。");
                    } catch (RuntimeException ex) { failures.add("一个旧账号列表无法转换。"); }
                }
                for (JsonObject row : rows) {
                    String type = NativeResourceFiles.text(row, "type", "");
                    String id = NativeResourceFiles.text(row, "accountID", "");
                    if (id.isBlank()) continue;
                    if (results.containsKey(id) && !Boolean.TRUE.equals(results.get(id).get("requiresReauth"))) continue;
                    try {
                        JsonObject secret = secrets.getOrDefault(id, new JsonObject());
                        if (!type.equals("offline") && secret.isEmpty()) throw new IOException("缺少在线凭据");
                        Account account = restore(type, row, secret);
                        results.put(id, serialize(account, type));
                    } catch (Exception ex) {
                        results.putIfAbsent(id, reauthenticationRecord(row, id, type));
                    }
                }
            } catch (Exception ex) { failures.add("一个 HMCL 账号文件无法读取。"); }
        }
        return Map.of("accounts", results.values(), "failures", failures, "metadataFiles", metadataFiles);
    }
    private static Map<String,Object> diagnostics(){StringBuilder report=new StringBuilder();for(String address:List.of("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json","https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json")){long start=System.nanoTime();HttpURLConnection connection=null;try{connection=(HttpURLConnection)URI.create(address).toURL().openConnection();connection.setConnectTimeout(6000);connection.setReadTimeout(6000);int status=connection.getResponseCode();if(status!=200)throw new IOException("HTTP "+status);byte[] data=connection.getInputStream().readNBytes(8_000_001);JsonObject manifest=JsonParser.parseString(new String(data,StandardCharsets.UTF_8)).getAsJsonObject();report.append("✓ ").append(URI.create(address).getHost()).append("  ").append(manifest.getAsJsonArray("versions").size()).append(" 个版本  ").append((System.nanoTime()-start)/1_000_000).append(" ms\n");}catch(Exception e){report.append("× ").append(URI.create(address).getHost()).append("  ").append(e.getClass().getSimpleName()).append('\n');}finally{if(connection!=null)connection.disconnect();}}return Map.of("report",report.toString());}
    private static final class Repository extends DefaultGameRepository{
        private final String run;
        Repository(Path root,String run){super(root);this.run=run;}
        @Override public Path getRunDirectory(String id){return run.isBlank()?getVersionRoot(id):Path.of(run);}
    }
}
