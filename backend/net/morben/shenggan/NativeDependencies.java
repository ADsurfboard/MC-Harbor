package net.morben.shenggan;

import com.google.gson.*;
import org.jackhuang.hmcl.download.DownloadProvider;
import java.io.*;
import java.net.*;
import java.nio.channels.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.function.Consumer;
import java.util.zip.ZipFile;

/** Optional pre-launch dependency completion. Stages and validates everything before adding new jars. */
final class NativeDependencies {
    record Reference(String source,String project,String version,boolean incompatible){}
    record Artifact(String filename,String url,long size,Map<String,String> hashes){}
    record Release(String source,String project,String id,String name,List<String> games,List<String> loaders,List<Artifact> files,List<Reference> dependencies){String key(){return source+":"+project;}}
    interface Catalog {
        List<Release> installed(List<Path> files)throws Exception;
        List<Release> versions(Reference ref)throws Exception;
        List<Reference> search(String modID)throws Exception;
        Path download(Release release,Artifact artifact,Path stage)throws Exception;
    }
    private final JsonObject input;private final Path data;private final DownloadProvider provider;private final Consumer<String> progress;
    private int probes;
    NativeDependencies(JsonObject input,Path data,DownloadProvider provider,Consumer<String> progress){this.input=input;this.data=data;this.provider=provider;this.progress=progress;}
    Map<String,Object> complete()throws Exception{return complete(new OnlineCatalog());}
    Map<String,Object> scan()throws Exception{
        var state=NativeModMetadata.scan(Path.of(text("runDirectory","")).toRealPath().resolve("mods"),text("loader","Forge"));
        return Map.of("mods",state.mods.stream().map(m->Map.of("id",m.id(),"version",m.version(),"file",m.file().toString(),"embedded",m.embedded())).toList(),"missing",state.missing(),"files",state.files.stream().map(Path::toString).toList());
    }
    Map<String,Object> complete(Catalog catalog)throws Exception{
        Path run=Path.of(text("runDirectory","")).toRealPath(),mods=run.resolve("mods"),harbor=run.resolve(".harbor");
        if(Files.isSymbolicLink(mods)||Files.isSymbolicLink(harbor))throw new IOException("实例管理目录或模组目录不能是符号链接。");
        Files.createDirectories(mods);Files.createDirectories(harbor);
        Path lockPath=harbor.resolve("dependency-completion.lock");if(Files.isSymbolicLink(lockPath))throw new IOException("前置补全锁文件不能是符号链接。");
        try(FileChannel channel=FileChannel.open(lockPath,StandardOpenOption.CREATE,StandardOpenOption.WRITE,LinkOption.NOFOLLOW_LINKS);FileLock lock=channel.tryLock()){
            if(lock==null)throw new IOException("此实例正在执行另一项前置补全。");ensureStopped(run);
            NativeModMetadata state=NativeModMetadata.scan(mods,text("loader","Forge"));state.missing();
            if(state.files.isEmpty())return Map.of("installed",List.of(),"checked",0);
            progress.accept("前置补全：检查本地声明与平台必需依赖");Map<Path,String> originals=stamps(mods);
            List<Release> roots=catalog.installed(state.files);Map<String,Release> installed=new LinkedHashMap<>();Deque<Reference> queue=new ArrayDeque<>();
            List<Reference> incompatible=new ArrayList<>();
            for(Release r:roots){installed.put(r.key(),r);queue.addAll(r.dependencies);for(Reference ref:r.dependencies)if(ref.incompatible)incompatible.add(ref);}
            Set<String> visited=new HashSet<>(),searched=new HashSet<>();Map<Path,Path> additions=new LinkedHashMap<>();List<String> names=new ArrayList<>();
            Path stage=Files.createTempDirectory(run,".harbor-dependencies-");
            try{
                while(true){
                    if(visited.size()>120||additions.size()>60)throw new IOException("前置依赖超过本次补全上限，原模组未修改。");
                    List<NativeModMetadata.Dependency> missing=state.missing();Selection selected;
                    if(queue.isEmpty()){
                        if(missing.isEmpty())break;
                        var needed=missing.get(0);if(!searched.add(needed.id()))throw missing(needed,"");selected=null;String reason="";
                        for(Reference ref:catalog.search(needed.id()))try{selected=select(catalog.versions(ref),needed.id(),state,mods,stage,catalog);if(selected!=null)break;}catch(IOException e){reason=e.getMessage();}
                        if(selected==null)throw missing(needed,reason.isBlank()?"未找到经过验证的兼容文件":reason);
                    }else{
                        Reference ref=queue.removeFirst();String key=ref.source+":"+ref.project;String visit=key+"@"+ref.version;
                        if(!visited.add(visit))continue;Release old=installed.get(key);
                        if(ref.incompatible){if(conflict(ref,installed,catalog))throw new IOException("平台声明前置不兼容："+Objects.toString(ref.project,ref.version));continue;}
                        if(old!=null){if(ref.version!=null&&!ref.version.isBlank()&&!old.id.equals(ref.version))throw new IOException("前置要求指定版本，实例已有其他版本："+old.name+"。未覆盖现有模组。");continue;}
                        List<Release> choices=catalog.versions(ref);
                        if(ref.version!=null&&!ref.version.isBlank())for(Release choice:choices){Release present=installed.get(choice.key());if(present!=null&&!present.id.equals(ref.version))throw new IOException("前置要求指定版本，实例已有其他版本："+present.name);}
                        selected=select(choices,null,state,mods,stage,catalog);
                        if(selected==null)throw new IOException("必要前置没有可验证的兼容版本："+Objects.toString(ref.project,ref.version));
                    }
                    if(selected.path!=null){state.merge(selected.metadata);additions.put(mods.resolve(selected.file.filename),selected.path);names.add(selected.release.name);}
                    installed.put(selected.release.key(),selected.release);queue.addAll(selected.release.dependencies);
                    for(Reference ref:selected.release.dependencies)if(ref.incompatible)incompatible.add(ref);
                }
                // A later transitive dependency may violate an earlier declaration.
                for(Reference ref:incompatible)if(conflict(ref,installed,catalog))throw new IOException("递归补入的前置与平台不兼容声明冲突："+Objects.toString(ref.project,ref.version)+"。原模组未修改。");
                ensureStopped(run);if(!originals.equals(stamps(mods)))throw new IOException("检查期间模组文件发生变化，请重新启动前置补全。");
                progress.accept(additions.isEmpty()?"前置补全：检查完成，无缺失":"前置补全：安装 "+additions.size()+" 个已校验的前置");
                List<Path> committed=new ArrayList<>();
                try{for(var e:additions.entrySet()){
                    if(Files.exists(e.getKey()))throw new IOException("同名文件已存在，未覆盖："+e.getKey().getFileName());
                    try{Files.createLink(e.getKey(),e.getValue());committed.add(e.getKey());Files.delete(e.getValue());}
                    catch(UnsupportedOperationException|FileSystemException unsupported){if(Files.exists(e.getKey()))throw unsupported;Files.move(e.getValue(),e.getKey());committed.add(e.getKey());}
                }}
                catch(Exception failure){Collections.reverse(committed);for(Path p:committed)try{Files.move(p,stage.resolve(p.getFileName()));}catch(Exception rollback){failure.addSuppressed(rollback);}throw failure;}
                return Map.of("installed",names,"checked",roots.size(),"localFiles",originals.size());
            }finally{try(var paths=Files.walk(stage)){for(Path p:paths.sorted(Comparator.reverseOrder()).toList())Files.deleteIfExists(p);}}
        }catch(OverlappingFileLockException e){throw new IOException("此实例正在执行另一项前置补全。");}
    }
    private record Selection(Release release,Artifact file,Path path,NativeModMetadata metadata){}
    private static boolean conflict(Reference ref,Map<String,Release> installed,Catalog catalog)throws Exception{
        if(ref.project!=null){Release current=installed.get(ref.source+":"+ref.project);return current!=null&&(ref.version==null||ref.version.isBlank()||current.id.equals(ref.version));}
        if(ref.version!=null&&!ref.version.isBlank())for(Release release:catalog.versions(ref)){Release current=installed.get(release.key());if(current!=null&&current.id.equals(ref.version))return true;}
        return false;
    }
    private Selection select(List<Release> versions,String wanted,NativeModMetadata state,Path mods,Path stage,Catalog catalog)throws Exception{
        String failure="";
        for(Release r:versions.stream().limit(30).toList()){
            if(!compatible(r))continue;Artifact f=r.files.stream().filter(a->a.filename.endsWith(".jar")).findFirst().orElse(null);if(f==null){failure="前置作者未开放兼容文件的直接下载，请从项目页面下载后导入。";continue;}
            if(++probes>80)throw new IOException("自动验证的候选文件过多，请先调整缺失前置；原模组未修改。");
            if(f.filename.contains("/")||f.filename.contains("\\")||f.filename.startsWith(".")||f.size<=0||f.size>256_000_000||f.hashes.isEmpty())throw new IOException("前置文件元数据无效："+r.name);
            progress.accept("前置补全：验证 "+r.name);Path file;
            try{file=catalog.download(r,f,stage);verify(file,f);}catch(IOException e){failure=e.getMessage();continue;}
            NativeModMetadata candidate=NativeModMetadata.archive(file,text("loader","Forge"));
            if(candidate.mods.isEmpty()||wanted!=null&&candidate.mods.stream().noneMatch(m->m.id().equals(wanted))){Files.deleteIfExists(file);continue;}
            Set<String> ids=new HashSet<>();state.mods.forEach(m->ids.add(m.id()));
            if(candidate.mods.stream().allMatch(m->ids.contains(m.id()))){Files.deleteIfExists(file);if(wanted==null)return new Selection(r,f,null,candidate);continue;}
            if(candidate.mods.stream().anyMatch(m->ids.contains(m.id())&&!m.embedded())){failure="文件包含已安装的模组 ID："+r.name;Files.deleteIfExists(file);continue;}
            if(Files.exists(mods.resolve(f.filename))||Files.exists(mods.resolve(f.filename+".disabled"))){failure="同名模组存在或已停用："+f.filename;Files.deleteIfExists(file);continue;}
            NativeModMetadata merged=new NativeModMetadata();merged.merge(state);merged.disabled.putAll(state.disabled);merged.merge(candidate);
            try{merged.missing();}catch(IOException e){failure=e.getMessage();Files.deleteIfExists(file);continue;}
            return new Selection(r,f,file,candidate);
        }
        if(!failure.isBlank())throw new IOException(failure);return null;
    }
    private boolean compatible(Release r){String loader=loader();return r.games.contains(text("version",""))&&(r.loaders.contains(loader)||loader.equals("quilt")&&r.loaders.contains("fabric"));}
    private String loader(){return switch(text("loader","Forge")){case "Cleanroom"->"forge";case "Legacy Fabric"->"fabric";default->text("loader","Forge").toLowerCase(Locale.ROOT);};}
    private String text(String key,String fallback){return input.has(key)&&!input.get(key).isJsonNull()?input.get(key).getAsString():fallback;}
    private static IOException missing(NativeModMetadata.Dependency d,String detail){return new IOException("前置补全未完成："+d.owner()+" 需要 "+d.id()+" "+String.join(" / ",d.ranges())+(detail.isBlank()?"":"（"+detail+"）")+"。原模组保留，未启动游戏。");}
    private static void ensureStopped(Path run)throws IOException{for(ProcessHandle p:ProcessHandle.allProcesses().toList()){String[] args=p.info().arguments().orElse(new String[0]);for(int i=0;i+1<args.length;i++)if(args[i].equals("--gameDir")&&Path.of(args[i+1]).toAbsolutePath().normalize().equals(run))throw new IOException("此实例已在游戏中运行，未修改模组。");}}
    private static Map<Path,String> stamps(Path dir)throws Exception{Map<Path,String> stamps=new LinkedHashMap<>();try(var paths=Files.list(dir)){for(Path p:paths.sorted().toList())if(Files.isRegularFile(p)&&!p.getFileName().toString().startsWith("."))stamps.put(p,sha(p,"SHA-256"));}return stamps;}
    static String sha(Path file,String algorithm)throws Exception{MessageDigest h=MessageDigest.getInstance(algorithm);try(InputStream in=Files.newInputStream(file)){byte[] buffer=new byte[256*1024];for(int n;(n=in.read(buffer))>0;)h.update(buffer,0,n);}return HexFormat.of().formatHex(h.digest());}
    static void verify(Path file,Artifact f)throws IOException{
        if(Files.size(file)!=f.size)throw new IOException("前置文件大小不符："+f.filename);String key=f.hashes.containsKey("sha512")?"sha512":f.hashes.containsKey("sha1")?"sha1":f.hashes.containsKey("md5")?"md5":"";
        if(key.isBlank())throw new IOException("前置缺少受支持的文件哈希。");try{if(!sha(file,key.equals("sha512")?"SHA-512":key.equals("sha1")?"SHA-1":"MD5").equalsIgnoreCase(f.hashes.get(key)))throw new IOException("前置哈希不符："+f.filename);}catch(IOException e){throw e;}catch(Exception e){throw new IOException(e);}
        try(ZipFile zip=new ZipFile(file.toFile())){if(zip.size()==0)throw new IOException("前置文件不是有效模组归档。");}
    }

    /** Official platform lookups identify installed projects by SHA-1 or exact CF fingerprint. */
    private final class OnlineCatalog implements Catalog {
        private final Map<String,List<Release>> memo=new HashMap<>();
        private JsonObject params(Reference ref){JsonObject p=input.deepCopy();p.addProperty("kind","mod");if(ref.project!=null)p.addProperty("project",ref.project);return p;}
        public List<Release> installed(List<Path> files)throws Exception{
            List<Release> result=new ArrayList<>();List<String> hashes=new ArrayList<>();for(Path p:files)hashes.add(sha(p,"SHA-1"));
            String key=NativeResourceFiles.digest((String.join(",",hashes)+text("version","")+loader()).getBytes(StandardCharsets.UTF_8));Path cache=data.resolve("dependency-index/"+key+".json");
            if(Files.isRegularFile(cache)&&System.currentTimeMillis()-Files.getLastModifiedTime(cache).toMillis()<86_400_000)try{Release[] saved=NativeResourceFiles.JSON.fromJson(Files.readString(cache),Release[].class);if(saved!=null)return new ArrayList<>(Arrays.asList(saved));}catch(RuntimeException|IOException ignored){}
            int good=0;
            try{JsonObject body=new JsonObject();body.addProperty("algorithm","sha1");body.add("hashes",NativeResourceFiles.JSON.toJsonTree(hashes));JsonObject response=NativeResourceFiles.http("https://api.modrinth.com/v2/version_files",body,false);for(var e:response.entrySet())result.add(mr(e.getValue().getAsJsonObject()));good++;}catch(IOException e){progress.accept("前置补全：Modrinth 索引暂不可用，检查其他来源");}
            try{List<Long> prints=new ArrayList<>();for(Path p:files)prints.add(NativeResourceFiles.fingerprint(p));JsonObject body=new JsonObject();body.add("fingerprints",NativeResourceFiles.JSON.toJsonTree(prints));JsonObject response=NativeResourceFiles.http("https://api.curseforge.com/v1/fingerprints/432",body,true).getAsJsonObject("data");for(JsonElement e:array(response,"exactMatches")){JsonObject f=e.getAsJsonObject().getAsJsonObject("file");result.add(cf(f.get("modId").getAsString(),f,false));}good++;}catch(IOException e){progress.accept("前置补全：CurseForge 索引暂不可用，保留本地声明检查");}
            if(good==0)throw new IOException("前置补全无法连接模组平台，未启动游戏。可重试或在设置中关闭前置补全。");
            if(good==2){Files.createDirectories(cache.getParent());Path temp=Files.createTempFile(cache.getParent(),".index-",".json");try{Files.writeString(temp,NativeResourceFiles.JSON.toJson(result));Files.move(temp,cache,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);}finally{Files.deleteIfExists(temp);}}
            return result;
        }
        public List<Release> versions(Reference ref)throws Exception{
            String key=ref.source+":"+ref.project+"@"+ref.version;if(memo.containsKey(key))return memo.get(key);List<Release> list=new ArrayList<>();
            if(ref.source.equals("modrinth")){
                if(ref.version!=null&&!ref.version.isBlank()){validID(ref.version);list.add(mr(NativeResourceFiles.http("https://api.modrinth.com/v2/version/"+ref.version,null,false)));}
                else{validID(ref.project);String query="?game_versions="+encode(NativeResourceFiles.JSON.toJson(List.of(text("version",""))))+"&loaders="+encode(NativeResourceFiles.JSON.toJson(loader().equals("quilt")?List.of("quilt","fabric"):List.of(loader())));for(JsonElement e:NativeResourceFiles.http("https://api.modrinth.com/v2/project/"+ref.project+"/version"+query,null,false).getAsJsonArray("data"))list.add(mr(e.getAsJsonObject()));}
            }else{NativeResources api=new NativeResources(params(ref),provider);for(JsonObject file:api.files(ref.project))list.add(cf(ref.project,file,false));}
            List<Release> result=list.stream().filter(NativeDependencies.this::compatible).toList();memo.put(key,result);return result;
        }
        public List<Reference> search(String id)throws Exception{
            List<Reference> refs=new ArrayList<>();String query=id.replace('_',' ').replace('-',' ');
            try{String facets=NativeResourceFiles.JSON.toJson(List.of(List.of("project_type:mod"),List.of("versions:"+text("version","")),List.of("categories:"+loader())));JsonObject response=NativeResourceFiles.http("https://api.modrinth.com/v2/search?limit=12&query="+encode(query)+"&facets="+encode(facets),null,false);for(JsonElement e:array(response,"hits"))refs.add(new Reference("modrinth",e.getAsJsonObject().get("project_id").getAsString(),null,false));}catch(IOException ignored){}
            try{JsonObject p=params(new Reference("curseforge",null,null,false));p.addProperty("query",query);JsonObject response=NativeResourceFiles.JSON.toJsonTree(new NativeResources(p,provider).search()).getAsJsonObject();for(JsonElement e:array(response,"hits")){refs.add(new Reference("curseforge",e.getAsJsonObject().get("projectId").getAsString(),null,false));if(refs.size()>=24)break;}}catch(IOException ignored){}
            return refs;
        }
        public Path download(Release r,Artifact f,Path stage)throws Exception{
            String hash=f.hashes.getOrDefault("sha512",f.hashes.getOrDefault("sha1",f.hashes.getOrDefault("md5","")));if(!hash.matches("[a-fA-F0-9]{32,128}"))throw new IOException("前置哈希格式无效。");
            Path cache=data.resolve("dependency-cache/"+hash+".jar");Files.createDirectories(cache.getParent());Path target=stage.resolve(UUID.randomUUID()+".jar");
            if(Files.isRegularFile(cache))try{verify(cache,f);Files.copy(cache,target);return target;}catch(IOException ignored){}
            URI url=URI.create(f.url);if(!"https".equals(url.getScheme()))throw new IOException("前置下载必须使用 HTTPS。");
            HttpURLConnection connection=(HttpURLConnection)url.toURL().openConnection();connection.setConnectTimeout(10000);connection.setReadTimeout(25000);connection.setRequestProperty("User-Agent","MC-Harbor/1.4 (dependency completion)");
            try{if(connection.getResponseCode()!=200)throw new IOException("前置下载失败："+r.name);if(Files.getFileStore(stage).getUsableSpace()<f.size+64_000_000)throw new IOException("磁盘空间不足以补全前置。");try(InputStream in=connection.getInputStream();OutputStream out=Files.newOutputStream(target,StandardOpenOption.CREATE_NEW)){byte[] buffer=new byte[128*1024];long count=0;for(int n;(n=in.read(buffer))>0;){count+=n;if(count>f.size)throw new IOException("前置下载大小超过声明值。");out.write(buffer,0,n);}}verify(target,f);
                if(!Files.exists(cache)){trimCache(cache.getParent(),f.size);Path temp=Files.createTempFile(cache.getParent(),".download-",".jar");try{Files.copy(target,temp,StandardCopyOption.REPLACE_EXISTING);Files.move(temp,cache,StandardCopyOption.ATOMIC_MOVE);}catch(FileAlreadyExistsException ignored){}finally{Files.deleteIfExists(temp);}}return target;
            }finally{connection.disconnect();}
        }
        private Release cf(String project,JsonObject file,boolean require)throws IOException{return addon("curseforge",new NativeResources(input,provider).version(project,file,require));}
    }
    private static void trimCache(Path directory,long incoming)throws IOException{
        try(var stream=Files.list(directory)){
            List<Path> files=stream.filter(p->p.getFileName().toString().matches("[a-fA-F0-9]{32,128}\\.jar")&&Files.isRegularFile(p,LinkOption.NOFOLLOW_LINKS)).sorted(Comparator.comparingLong(p->{try{return Files.getLastModifiedTime(p).toMillis();}catch(IOException e){return 0;}})).toList();
            long total=incoming;for(Path p:files)total+=Files.size(p);for(Path p:files){if(total<=384_000_000L)break;long size=Files.size(p);Files.delete(p);total-=size;}
        }
    }
    private static Release mr(JsonObject object){
        List<Artifact> files=new ArrayList<>();List<JsonElement> ordered=new ArrayList<>();array(object,"files").forEach(ordered::add);ordered.sort(Comparator.comparing(e->!e.getAsJsonObject().get("primary").getAsBoolean()));
        for(JsonElement e:ordered){JsonObject f=e.getAsJsonObject();files.add(artifact(f));}
        List<Reference> deps=new ArrayList<>();for(JsonElement e:array(object,"dependencies")){JsonObject d=e.getAsJsonObject();String type=str(d,"dependency_type","");if(type.equals("required")||type.equals("incompatible"))deps.add(new Reference("modrinth",str(d,"project_id",null),str(d,"version_id",null),type.equals("incompatible")));}
        return new Release("modrinth",str(object,"project_id",""),str(object,"id",""),str(object,"name",""),strings(object,"game_versions"),strings(object,"loaders"),files,deps);
    }
    private static Release addon(String source,Map<String,Object> value){JsonObject o=NativeResourceFiles.JSON.toJsonTree(value).getAsJsonObject();List<Artifact> files=new ArrayList<>();for(JsonElement e:array(o,"files"))files.add(artifact(e.getAsJsonObject()));List<Reference> deps=new ArrayList<>();for(JsonElement e:array(o,"dependencies")){JsonObject d=e.getAsJsonObject();if(str(d,"dependencyType","").equals("required"))deps.add(new Reference(source,str(d,"projectId",null),null,false));}return new Release(source,str(o,"projectId",""),str(o,"id",""),str(o,"name",""),strings(o,"gameVersions"),strings(o,"loaders"),files,deps);}
    private static Artifact artifact(JsonObject f){Map<String,String> hashes=new LinkedHashMap<>();f.getAsJsonObject("hashes").entrySet().forEach(e->hashes.put(e.getKey(),e.getValue().getAsString()));return new Artifact(str(f,"filename",""),str(f,"url",""),f.get("size").getAsLong(),hashes);}
    private static void validID(String id)throws IOException{if(id==null||!id.matches("[A-Za-z0-9_-]{1,80}"))throw new IOException("前置项目 ID 无效。");}
    private static String encode(String s){return URLEncoder.encode(s,StandardCharsets.UTF_8);}
    private static String str(JsonObject o,String key,String fallback){return o.has(key)&&!o.get(key).isJsonNull()?o.get(key).getAsString():fallback;}
    private static JsonArray array(JsonObject o,String key){return o!=null&&o.has(key)&&o.get(key).isJsonArray()?o.getAsJsonArray(key):new JsonArray();}
    private static List<String> strings(JsonObject o,String key){List<String> result=new ArrayList<>();for(JsonElement e:array(o,key))result.add(e.getAsString());return result;}
}
