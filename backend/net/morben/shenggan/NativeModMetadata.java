package net.morben.shenggan;

import com.google.gson.*;
import org.jackhuang.hmcl.util.versioning.VersionNumber;
import org.tomlj.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.jar.Manifest;
import java.util.regex.*;
import java.util.zip.*;

/** Loader metadata, embedded providers and required client dependencies; no mod classes are executed. */
final class NativeModMetadata {
    record Dependency(String owner,String id,List<String> ranges,boolean forbidden){}
    record Mod(String id,String version,Path file,boolean embedded){}
    static final Set<String> BUILTINS=Set.of("minecraft","java","forge","neoforge","fabricloader","quilt_loader","cleanroom","fml","modloader","liteloader");
    final List<Mod> mods=new ArrayList<>();
    final List<Dependency> dependencies=new ArrayList<>();
    final List<Path> files=new ArrayList<>();
    final Map<Path,NativeModMetadata> disabled=new LinkedHashMap<>();
    void merge(NativeModMetadata other){mods.addAll(other.mods);dependencies.addAll(other.dependencies);files.addAll(other.files);}
    static NativeModMetadata scan(Path directory,String loader)throws IOException{
        NativeModMetadata all=new NativeModMetadata();
        if(!Files.isDirectory(directory))return all;
        try(var stream=Files.list(directory)){
            for(Path file:stream.sorted().toList()){
                String name=file.getFileName().toString();if(!name.endsWith(".jar")&&!name.endsWith(".jar.disabled"))continue;
                if(Files.isSymbolicLink(file)||!Files.isRegularFile(file,LinkOption.NOFOLLOW_LINKS))throw new IOException("模组文件不能是符号链接："+name);
                NativeModMetadata read=archive(file,loader);
                if(name.endsWith(".disabled"))all.disabled.put(file,read);else{all.files.add(file);all.merge(read);}
            }
        }return all;
    }
    static NativeModMetadata archive(Path file,String loader)throws IOException{
        try(ZipFile zip=new ZipFile(file.toFile())){
            Map<String,byte[]> metadata=new HashMap<>();
            for(String name:List.of("fabric.mod.json","quilt.mod.json","META-INF/mods.toml","META-INF/neoforge.mods.toml","META-INF/MANIFEST.MF","META-INF/jarjar/metadata.json","mcmod.info")){
                ZipEntry e=zip.getEntry(name);if(e!=null)try(InputStream in=zip.getInputStream(e)){metadata.put(name,NativeResourceFiles.bounded(in,2_000_000));}
            }
            NativeModMetadata result=parse(metadata,file,loader,false);
            List<String> nested=nested(metadata,loader);
            for(String name:nested){if(!NativeResourceFiles.safe(name))throw new IOException("内嵌模组路径无效。");ZipEntry e=zip.getEntry(name);if(e==null)throw new IOException("声明的内嵌模组不存在："+name);try(InputStream in=zip.getInputStream(e)){result.merge(nestedArchive(NativeResourceFiles.bounded(in,48_000_000),file,loader,1));}}
            return result;
        }catch(RuntimeException e){throw new IOException("无法读取模组元数据："+file.getFileName(),e);}
    }
    private static NativeModMetadata nestedArchive(byte[] bytes,Path owner,String loader,int depth)throws IOException{
        if(depth>4)throw new IOException("内嵌模组层级过深："+owner.getFileName());
        Map<String,byte[]> contents=new HashMap<>();
        // Only declared children and metadata are retained, never arbitrary textures/classes.
        try(ZipInputStream zip=new ZipInputStream(new ByteArrayInputStream(bytes))){for(ZipEntry e;(e=zip.getNextEntry())!=null;){String name=e.getName();if(name.equals("fabric.mod.json")||name.equals("quilt.mod.json")||name.equals("META-INF/mods.toml")||name.equals("META-INF/neoforge.mods.toml")||name.equals("META-INF/jarjar/metadata.json")||name.equals("META-INF/MANIFEST.MF"))contents.put(name,NativeResourceFiles.bounded(zip,2_000_000));}}
        NativeModMetadata result=parse(contents,owner,loader,true);List<String> wanted=nested(contents,loader);
        if(!wanted.isEmpty())try(ZipInputStream zip=new ZipInputStream(new ByteArrayInputStream(bytes))){for(ZipEntry e;(e=zip.getNextEntry())!=null;)if(wanted.contains(e.getName()))result.merge(nestedArchive(NativeResourceFiles.bounded(zip,48_000_000),owner,loader,depth+1));}
        return result;
    }
    private static NativeModMetadata parse(Map<String,byte[]> contents,Path file,String loader,boolean embedded)throws IOException{
        NativeModMetadata out=new NativeModMetadata();boolean fabric=Set.of("Fabric","Legacy Fabric","Quilt").contains(loader);
        if(loader.equals("Quilt")&&contents.containsKey("quilt.mod.json")){
            JsonObject q=json(contents,"quilt.mod.json").getAsJsonObject("quilt_loader");String id=text(q,"id","");add(out,id,text(q,"version",""),file,embedded);
            for(JsonElement e:array(q,"provides")){JsonObject v=e.isJsonObject()?e.getAsJsonObject():null;add(out,v==null?e.getAsString():text(v,"id",""),v==null?text(q,"version",""):text(v,"version",text(q,"version","")),file,true);}
            for(JsonElement e:array(q,"depends"))quiltDependency(out,id,e);
        }else if(fabric&&contents.containsKey("fabric.mod.json")){
            JsonObject m=json(contents,"fabric.mod.json");if(text(m,"environment","*").equals("server"))return out;
            String id=text(m,"id","");add(out,id,text(m,"version",""),file,embedded);
            for(JsonElement e:array(m,"provides"))add(out,e.getAsString(),text(m,"version",""),file,true);
            for(String key:List.of("depends","breaks"))if(m.has(key)&&m.get(key).isJsonObject())for(var dep:m.getAsJsonObject(key).entrySet())out.dependencies.add(new Dependency(id,dep.getKey(),ranges(dep.getValue()),key.equals("breaks")));
        }else if(!fabric){
            String name=loader.equals("NeoForge")&&contents.containsKey("META-INF/neoforge.mods.toml")?"META-INF/neoforge.mods.toml":"META-INF/mods.toml";
            if(contents.containsKey(name)){
                TomlParseResult toml=Toml.parse(new String(contents.get(name),StandardCharsets.UTF_8));if(toml.hasErrors())throw new IOException("TOML 格式无效："+file.getFileName());
                String manifestVersion="";if(contents.containsKey("META-INF/MANIFEST.MF"))manifestVersion=Objects.toString(new Manifest(new ByteArrayInputStream(contents.get("META-INF/MANIFEST.MF"))).getMainAttributes().getValue("Implementation-Version"),"");
                TomlArray mods=toml.getArray("mods");if(mods!=null)for(int i=0;i<mods.size();i++){TomlTable m=mods.getTable(i);String version=Objects.toString(m.getString("version"),"").replace("${file.jarVersion}",manifestVersion);add(out,m.getString("modId"),version,file,embedded);}
                TomlTable deps=toml.getTable("dependencies");if(deps!=null)for(String owner:deps.keySet()){TomlArray list=deps.getArray(List.of(owner));if(list==null)continue;for(int i=0;i<list.size();i++){TomlTable d=list.getTable(i);String side=Objects.toString(d.getString("side"),"BOTH");if(side.equalsIgnoreCase("SERVER"))continue;String type=Objects.toString(d.getString("type"),"");boolean required=type.equals("required")||Boolean.TRUE.equals(d.getBoolean("mandatory"));boolean forbidden=type.equals("incompatible");if(required||forbidden)out.dependencies.add(new Dependency(owner,d.getString("modId"),List.of(Objects.toString(d.getString("versionRange"),"*")),forbidden));}}
            }else if(contents.containsKey("mcmod.info")){
                JsonElement parsed=JsonParser.parseString(new String(contents.get("mcmod.info"),StandardCharsets.UTF_8));JsonArray list=parsed.isJsonArray()?parsed.getAsJsonArray():array(parsed.getAsJsonObject(),"modList");
                for(JsonElement e:list){JsonObject m=e.getAsJsonObject();String id=text(m,"modid","");add(out,id,text(m,"version",""),file,embedded);for(JsonElement d:array(m,"requiredMods")){String v=d.getAsString();String[] pieces=v.split("@",2);out.dependencies.add(new Dependency(id,pieces[0],List.of(pieces.length>1?pieces[1]:"*"),false));}}
            }
        }
        return out;
    }
    private static void quiltDependency(NativeModMetadata out,String owner,JsonElement e)throws IOException{
        if(e.isJsonPrimitive()){out.dependencies.add(new Dependency(owner,e.getAsString(),List.of("*"),false));return;}
        if(!e.isJsonObject())throw new IOException("Quilt 依赖包含尚不支持的组合条件，请在游戏中检查："+owner);
        JsonObject d=e.getAsJsonObject();if(d.has("optional")&&d.get("optional").getAsBoolean())return;
        if(d.has("unless"))throw new IOException("Quilt 条件依赖需由加载器确认，未擅自补入："+owner);
        out.dependencies.add(new Dependency(owner,text(d,"id",""),d.has("versions")?ranges(d.get("versions")):List.of("*"),false));
    }
    private static List<String> nested(Map<String,byte[]> contents,String loader){
        List<String> list=new ArrayList<>();String jsonName=loader.equals("Quilt")&&contents.containsKey("quilt.mod.json")?"quilt.mod.json":"fabric.mod.json";
        if(Set.of("Fabric","Legacy Fabric","Quilt").contains(loader)&&contents.containsKey(jsonName)){
            JsonObject q=json(contents,jsonName);for(JsonElement e:array(q,"jars"))list.add(e.isJsonPrimitive()?e.getAsString():text(e.getAsJsonObject(),"file",""));
        }else if(contents.containsKey("META-INF/jarjar/metadata.json"))for(JsonElement e:array(json(contents,"META-INF/jarjar/metadata.json"),"jars"))list.add(text(e.getAsJsonObject(),"path",""));
        return list.stream().filter(s->!s.isBlank()).distinct().toList();
    }
    private static void add(NativeModMetadata out,String id,String version,Path path,boolean embedded){if(id!=null&&id.matches("[A-Za-z0-9_.-]{1,128}"))out.mods.add(new Mod(id,version,path,embedded));}
    List<Dependency> missing()throws IOException{
        List<Dependency> missing=new ArrayList<>();
        for(Dependency dep:dependencies){if(BUILTINS.contains(dep.id))continue;List<Mod> available=mods.stream().filter(m->m.id.equals(dep.id)).toList();
            boolean found=false;for(Mod mod:available)if(matches(mod.version,dep.ranges))found=true;
            if(dep.forbidden){if(found)throw new IOException("模组不兼容："+dep.owner+" 与 "+dep.id+"（"+String.join(" / ",dep.ranges)+"）");continue;}
            if(!available.isEmpty()&&!found)throw new IOException("前置版本冲突："+dep.owner+" 需要 "+dep.id+" "+String.join(" / ",dep.ranges)+"。现有版本保留，请先调整。");
            if(!found){for(var entry:disabled.entrySet())if(entry.getValue().mods.stream().anyMatch(m->m.id.equals(dep.id)))throw new IOException("所需前置已被停用："+dep.id+"。请在模组视图中手动启用。");missing.add(dep);}
        }return missing;
    }
    static boolean matches(String version,List<String> ranges)throws IOException{for(String range:ranges)if(matchOne(version,range))return true;return false;}
    private static boolean matchOne(String version,String raw)throws IOException{
        String range=raw.trim();if(range.isBlank()||range.equals("*")||range.equals("(,)"))return true;
        if(version.isBlank()||version.contains("${"))throw new IOException("无法确认前置的声明版本："+version);
        if(range.contains("||")){for(String part:range.split("\\|\\|"))if(matchOne(version,part))return true;return false;}
        if(range.startsWith("[")||range.startsWith("(")){
            Matcher matcher=Pattern.compile("([\\[(])([^\\]()]*)[\\])]" ).matcher(range);boolean any=false;int end=0;
            while(matcher.find()){if(!range.substring(end,matcher.start()).matches("[,\\s]*"))throw new IOException("无法确认版本范围："+range);end=matcher.end();String[] limits=matcher.group(2).split(",",-1);if(limits.length==1){if(compare(version,limits[0])==0)any=true;}else if(limits.length==2){boolean low=limits[0].isBlank()||compare(version,limits[0])>(matcher.group(1).equals("[")?-1:0);boolean high=limits[1].isBlank()||compare(version,limits[1])<(range.charAt(matcher.end()-1)==']'?1:0);if(low&&high)any=true;}else throw new IOException("版本范围无效："+range);}
            if(end!=range.length())throw new IOException("无法确认版本范围："+range);return any;
        }
        for(String token:range.replace(","," ").trim().split("\\s+")){
            if(token.isBlank()||token.equals("*"))continue;
            Matcher term=Pattern.compile("(>=|<=|>|<|=|\\^|~)?([A-Za-z0-9_.+*xX-]+)").matcher(token);if(!term.matches())throw new IOException("尚不支持的版本条件："+range);
            String op=Objects.toString(term.group(1),"="),v=term.group(2);
            if(v.matches(".*(?:[.*xX]).*")){String[] pieces=v.split("\\.");boolean wildcard=Arrays.stream(pieces).anyMatch(s->s.equals("*")||s.equalsIgnoreCase("x"));if(wildcard){if(!op.equals("="))throw new IOException("无法确认通配版本条件："+range);String[] actual=version.split("[.+-]");for(int i=0;i<pieces.length;i++){if(pieces[i].equals("*")||pieces[i].equalsIgnoreCase("x"))break;if(i>=actual.length||!pieces[i].equals(actual[i]))return false;}continue;}}
            int c=compare(version,v);switch(op){case ">="->{if(c<0)return false;}case "<="->{if(c>0)return false;}case ">"->{if(c<=0)return false;}case "<"->{if(c>=0)return false;}case "="->{if(c!=0)return false;}case "^","~"->{String[] p=v.split("[.+-]");int[] n={0,0,0};try{for(int i=0;i<Math.min(3,p.length);i++)n[i]=Integer.parseInt(p[i]);}catch(Exception e){throw new IOException("无法确认语义版本范围："+range);}int position=op.equals("~")?(p.length>=2?1:0):n[0]>0?0:n[1]>0?1:2;n[position]++;for(int i=position+1;i<3;i++)n[i]=0;String upper=n[0]+"."+n[1]+"."+n[2];if(c<0||compare(version,upper)>=0)return false;}default->throw new IOException("无法确认版本条件："+range);}
        }return true;
    }
    private static int compare(String a,String b){return VersionNumber.asVersion(a.trim()).compareTo(VersionNumber.asVersion(b.trim()));}
    private static List<String> ranges(JsonElement element){if(element.isJsonArray()){List<String> out=new ArrayList<>();for(JsonElement e:element.getAsJsonArray())out.add(e.getAsString());return out;}return List.of(element.getAsString());}
    private static JsonObject json(Map<String,byte[]> contents,String name){return JsonParser.parseString(new String(contents.get(name),StandardCharsets.UTF_8)).getAsJsonObject();}
    private static JsonArray array(JsonObject o,String key){return o!=null&&o.has(key)&&o.get(key).isJsonArray()?o.getAsJsonArray(key):new JsonArray();}
    private static String text(JsonObject o,String key,String fallback){return o!=null&&o.has(key)&&!o.get(key).isJsonNull()?o.get(key).getAsString():fallback;}
}
