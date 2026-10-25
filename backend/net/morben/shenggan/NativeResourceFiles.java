package net.morben.shenggan;

import com.google.gson.*;
import org.jackhuang.hmcl.addon.repository.CurseForgeRemoteAddonRepository;
import org.jackhuang.hmcl.util.MurmurHash2;
import javax.imageio.ImageIO;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.regex.*;
import java.util.zip.*;

/** Original archive artwork and exact-file platform indexing; never guesses a project by name. */
final class NativeResourceFiles {
    static final Gson JSON=new GsonBuilder().disableHtmlEscaping().setPrettyPrinting().create();
    static String digest(byte[] bytes)throws Exception{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-1").digest(bytes));}
    static byte[] bounded(InputStream stream,int limit)throws IOException{byte[] bytes=stream.readNBytes(limit+1);if(bytes.length>limit)throw new IOException("实例资源元数据超过大小限制");return bytes;}
    static JsonObject object(Path path){try{return JsonParser.parseString(Files.readString(path)).getAsJsonObject();}catch(Exception e){return new JsonObject();}}
    static String text(JsonObject object,String key,String fallback){try{return object.get(key).getAsString();}catch(Exception e){return fallback;}}
    static boolean language(String path){return path.matches("assets/[a-z0-9_.-]+/lang/[A-Za-z0-9_.-]+\\.(json|lang)");}
    static boolean safe(String path){return !path.startsWith("/")&&!path.contains("\\")&&Arrays.stream(path.split("/")).noneMatch(s->s.equals(".."));}
    private static String iconValue(JsonElement value){if(value==null)return null;if(value.isJsonPrimitive())return value.getAsString();if(value.isJsonObject())return value.getAsJsonObject().entrySet().stream().sorted(Comparator.comparingInt(e->{try{return -Integer.parseInt(e.getKey());}catch(Exception ignored){return 0;}})).map(e->e.getValue().getAsString()).findFirst().orElse(null);return null;}
    private static String metadataLogo(Path file){
        if(!Files.isRegularFile(file))return null;
        try(ZipFile zip=new ZipFile(file.toFile())){for(String name:List.of("fabric.mod.json","quilt.mod.json","mcmod.info","META-INF/mods.toml","META-INF/neoforge.mods.toml")){
            ZipEntry entry=zip.getEntry(name);if(entry==null)continue;String content;try(InputStream in=zip.getInputStream(entry)){content=new String(bounded(in,512_000),StandardCharsets.UTF_8);}
            if(name.endsWith("toml")){Matcher match=Pattern.compile("(?m)^\\s*logoFile\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']").matcher(content);if(match.find())return match.group(1);}
            else{JsonElement parsed=JsonParser.parseString(content);if(parsed.isJsonArray()&&parsed.getAsJsonArray().size()>0)parsed=parsed.getAsJsonArray().get(0);JsonObject object=parsed.getAsJsonObject();if(name.equals("quilt.mod.json"))object=object.getAsJsonObject("quilt_loader").getAsJsonObject("metadata");String logo=iconValue(object.get(name.equals("mcmod.info")?"logoFile":"icon"));if(logo!=null&&!logo.isBlank())return logo;}
        }}catch(Exception ignored){}return null;
    }
    static String icon(Path file,String preferred,Path data){
        try{
            List<String> names=new ArrayList<>();if(preferred!=null&&!preferred.isBlank())names.add(preferred.replaceFirst("^/",""));String metadata=metadataLogo(file);if(metadata!=null)names.add(metadata);names.addAll(List.of("pack.png","icon.png","logo.png","shaders/icon.png","shaders/pack.png"));
            String stamp=file.toAbsolutePath()+":"+Files.getLastModifiedTime(file).toMillis()+":"+(Files.isDirectory(file)?0:Files.size(file));
            Path directory=data.resolve("resource-icons");Files.createDirectories(directory);
            for(String name:names){if(!safe(name))continue;Path target=directory.resolve(digest((stamp+name).getBytes(StandardCharsets.UTF_8))+".png");if(Files.isRegularFile(target))return target.toString();byte[] bytes;
                if(Files.isDirectory(file)){Path source=file.resolve(name).normalize();if(!source.startsWith(file.normalize())||!Files.isRegularFile(source)||Files.isSymbolicLink(source))continue;try(InputStream in=Files.newInputStream(source)){bytes=bounded(in,4_000_000);}}
                else{try(ZipFile zip=new ZipFile(file.toFile())){ZipEntry entry=zip.getEntry(name);if(entry==null||entry.isDirectory())continue;try(InputStream in=zip.getInputStream(entry)){bytes=bounded(in,4_000_000);}}}
                java.awt.image.BufferedImage image;try(var input=ImageIO.createImageInputStream(new ByteArrayInputStream(bytes))){var readers=ImageIO.getImageReaders(input);if(!readers.hasNext())continue;var reader=readers.next();try{reader.setInput(input,true,true);if(reader.getWidth(0)>4096||reader.getHeight(0)>4096)continue;image=reader.read(0);}finally{reader.dispose();}}if(image==null)continue;Path stage=Files.createTempFile(directory,"icon-",".png");try{if(!ImageIO.write(image,"png",stage.toFile()))continue;try{Files.move(stage,target);}catch(FileAlreadyExistsException ignored){}}finally{Files.deleteIfExists(stage);}return target.toString();
            }
        }catch(Exception ignored){}return null;
    }
    static int languageCount(Path file){try{if(Files.isDirectory(file)){try(var paths=Files.walk(file.resolve("assets"),8)){return (int)paths.filter(p->Files.isRegularFile(p,LinkOption.NOFOLLOW_LINKS)&&language(file.relativize(p).toString())).limit(10001).count();}}try(ZipFile zip=new ZipFile(file.toFile())){return (int)zip.stream().filter(e->language(e.getName())&&!e.isDirectory()).limit(10001).count();}}catch(Exception e){return 0;}}
    static Map<String,String> links(String address){Map<String,String> links=new LinkedHashMap<>();try{URI uri=URI.create(address);String host=Objects.toString(uri.getHost(),"").toLowerCase(Locale.ROOT);if(!List.of("http","https").contains(uri.getScheme()))return links;if(host.equals("modrinth.com")||host.equals("www.modrinth.com"))links.put("modrinth",address);if(host.equals("curseforge.com")||host.equals("www.curseforge.com"))links.put("curseforge",address);}catch(Exception ignored){}return links;}
    static Map<String,Object> item(Path file,String kind,String name,String preferred,String address,Path data){Map<String,Object> item=new LinkedHashMap<>();item.put("path",file.toAbsolutePath().toString());item.put("name",name);item.put("kind",kind);item.put("enabled",!file.getFileName().toString().endsWith(".disabled"));item.put("iconPath",icon(file,preferred,data));item.put("links",links(address));item.put("languageFiles",languageCount(file));return item;}
    static JsonObject http(String address,JsonObject body,boolean curse)throws IOException{
        HttpURLConnection c=(HttpURLConnection)URI.create(address).toURL().openConnection();c.setConnectTimeout(9000);c.setReadTimeout(16000);c.setRequestProperty("Accept","application/json");c.setRequestProperty("User-Agent","MC-harbor/1.3 (native instance resource manager)");
        if(curse&&"api.curseforge.com".equals(c.getURL().getHost()))c.setRequestProperty("x-api-key",CurseForgeRemoteAddonRepository.API_KEY);
        try{if(body!=null){c.setRequestMethod("POST");c.setDoOutput(true);c.setRequestProperty("Content-Type","application/json");try(OutputStream out=c.getOutputStream()){out.write(body.toString().getBytes(StandardCharsets.UTF_8));}}int status=c.getResponseCode();if(status!=200)throw new IOException("资源平台暂不可用（HTTP "+status+"）");try(InputStream in=c.getInputStream()){JsonElement parsed=JsonParser.parseString(new String(bounded(in,24_000_000),StandardCharsets.UTF_8));if(parsed.isJsonObject())return parsed.getAsJsonObject();JsonObject wrapped=new JsonObject();wrapped.add("data",parsed);return wrapped;}}finally{c.disconnect();}
    }
    private static String fileHash(Path path)throws Exception{MessageDigest digest=MessageDigest.getInstance("SHA-1");try(InputStream in=Files.newInputStream(path)){byte[] b=new byte[512*1024];for(int n;(n=in.read(b))>0;)digest.update(b,0,n);}return HexFormat.of().formatHex(digest.digest());}
    static long fingerprint(Path file)throws IOException{
        long length=0;byte[] bytes=new byte[512*1024];try(InputStream in=Files.newInputStream(file)){for(int n;(n=in.read(bytes))>0;)for(int i=0;i<n;i++)if(bytes[i]!=9&&bytes[i]!=10&&bytes[i]!=13&&bytes[i]!=32)length++;}
        var checksum=MurmurHash2.hash32(length,1);try(InputStream in=Files.newInputStream(file)){for(int n;(n=in.read(bytes))>0;){int count=0;for(int i=0;i<n;i++)if(bytes[i]!=9&&bytes[i]!=10&&bytes[i]!=13&&bytes[i]!=32)bytes[count++]=bytes[i];checksum.update(bytes,0,count);}}return checksum.getValue();
    }
    @SuppressWarnings("unchecked") static Map<String,Object> index(List<Map<String,Object>> items,Path run,Path data,boolean resolve)throws Exception{
        Path cache=data.resolve("resource-index/"+digest(run.toString().getBytes(StandardCharsets.UTF_8))+".json");JsonObject previous=object(cache);Map<String,List<Map<String,Object>>> byHash=new LinkedHashMap<>();Map<Long,List<Map<String,Object>>> byFingerprint=new LinkedHashMap<>();List<String> warnings=new ArrayList<>();JsonObject saved=new JsonObject();
        JsonObject receipts=object(run.resolve(".harbor/resource-sources.json"));
        for(var item:items){Path file=Path.of((String)item.get("path"));Map<String,String> links=(Map<String,String>)item.get("links");String key=digest((file+":"+Files.getLastModifiedTime(file).toMillis()+":"+(Files.isDirectory(file)?0:Files.size(file))).getBytes(StandardCharsets.UTF_8));item.put("revision",key);JsonObject old=previous.has(key)?previous.getAsJsonObject(key):new JsonObject();if(old.has("links"))old.getAsJsonObject("links").entrySet().forEach(e->links.put(e.getKey(),e.getValue().getAsString()));if(receipts.has(file.getFileName().toString()))receipts.getAsJsonObject(file.getFileName().toString()).entrySet().forEach(e->{if(!links(e.getValue().getAsString()).isEmpty())links.putAll(links(e.getValue().getAsString()));});
            if(resolve&&Files.isRegularFile(file)&&Files.size(file)<250_000_000L&&(!old.has("checkedAt")||System.currentTimeMillis()-old.get("checkedAt").getAsLong()>86_400_000L)){
                byHash.computeIfAbsent(fileHash(file),h->new ArrayList<>()).add(item);byFingerprint.computeIfAbsent(fingerprint(file),h->new ArrayList<>()).add(item);
            }
            JsonObject record=new JsonObject();record.add("links",JSON.toJsonTree(links));if(old.has("checkedAt"))record.add("checkedAt",old.get("checkedAt"));saved.add(key,record);
        }
        boolean mrOK=false,cfOK=false;
        if(!byHash.isEmpty())try{JsonObject body=new JsonObject();body.addProperty("algorithm","sha1");body.add("hashes",JSON.toJsonTree(byHash.keySet()));JsonObject result=http("https://api.modrinth.com/v2/version_files",body,false);Map<String,List<Map<String,Object>>> projects=new LinkedHashMap<>();for(var e:result.entrySet()){String id=text(e.getValue().getAsJsonObject(),"project_id","");if(!id.isEmpty())projects.computeIfAbsent(id,k->new ArrayList<>()).addAll(byHash.getOrDefault(e.getKey(),List.of()));}if(!projects.isEmpty()){String query=URLEncoder.encode(JSON.toJson(projects.keySet()),StandardCharsets.UTF_8);for(JsonElement e:http("https://api.modrinth.com/v2/projects?ids="+query,null,false).getAsJsonArray("data")){JsonObject p=e.getAsJsonObject();String address="https://modrinth.com/"+text(p,"project_type","mod")+"/"+text(p,"slug",text(p,"id",""));for(var item:projects.getOrDefault(text(p,"id",""),List.of()))((Map<String,String>)item.get("links")).put("modrinth",address);}}mrOK=true;}catch(Exception e){warnings.add("Modrinth 来源索引暂不可用");}
        if(!byFingerprint.isEmpty())try{JsonObject body=new JsonObject();body.add("fingerprints",JSON.toJsonTree(byFingerprint.keySet()));JsonObject result=http("https://api.curseforge.com/v1/fingerprints/432",body,true).getAsJsonObject("data");Map<String,List<Map<String,Object>>> projects=new LinkedHashMap<>();if(result.has("exactMatches"))for(JsonElement e:result.getAsJsonArray("exactMatches")){JsonObject match=e.getAsJsonObject(),file=match.getAsJsonObject("file");long fingerprint=file.get("fileFingerprint").getAsLong();projects.computeIfAbsent(file.get("modId").getAsString(),k->new ArrayList<>()).addAll(byFingerprint.getOrDefault(fingerprint,List.of()));}if(!projects.isEmpty()){JsonObject request=new JsonObject();request.add("modIds",JSON.toJsonTree(projects.keySet().stream().map(Integer::parseInt).toList()));for(JsonElement e:http("https://api.curseforge.com/v1/mods",request,true).getAsJsonArray("data")){JsonObject project=e.getAsJsonObject();String url=text(project.getAsJsonObject("links"),"websiteUrl","");if(!url.isEmpty())for(var item:projects.getOrDefault(project.get("id").getAsString(),List.of()))((Map<String,String>)item.get("links")).putAll(links(url));}}cfOK=true;}catch(Exception e){warnings.add("CurseForge 来源索引暂不可用");}
        for(var item:items){JsonObject record=saved.getAsJsonObject((String)item.get("revision"));record.add("links",JSON.toJsonTree(item.get("links")));if(resolve&&mrOK&&cfOK)record.addProperty("checkedAt",System.currentTimeMillis());}
        Files.createDirectories(cache.getParent());Files.writeString(cache,JSON.toJson(saved),StandardCharsets.UTF_8);return Map.of("resources",items,"warnings",warnings);
    }
}
