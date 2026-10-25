package net.morben.shenggan;

import com.google.gson.*;
import org.jackhuang.hmcl.addon.repository.CurseForgeRemoteAddonRepository;
import org.jackhuang.hmcl.download.DownloadProvider;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** CurseForge requests retain the original engine's API identity and download-source candidates. */
final class NativeResources {
    private final JsonObject input;private final DownloadProvider provider;
    NativeResources(JsonObject input,DownloadProvider provider){this.input=input;this.provider=provider;}
    private String text(String name,String fallback){return input.has(name)&&!input.get(name).isJsonNull()?input.get(name).getAsString():fallback;}
    private static String string(JsonObject object,String name,String fallback){return object.has(name)&&!object.get(name).isJsonNull()?object.get(name).getAsString():fallback;}
    private static long number(JsonObject object,String name,long fallback){return object.has(name)&&!object.get(name).isJsonNull()?object.get(name).getAsLong():fallback;}
    private static JsonArray array(JsonObject object,String key){return object.has(key)&&object.get(key).isJsonArray()?object.getAsJsonArray(key):new JsonArray();}
    private int loader(){return switch(text("loader","")){case "Forge","Cleanroom"->1;case "Fabric","Legacy Fabric"->4;case "Quilt"->5;case "NeoForge"->6;default->0;};}
    private int section(){return switch(text("kind","mod")){case "mod"->6;case "resourcepack"->12;case "shader"->6552;case "world"->17;case "modpack"->4471;default->throw new IllegalArgumentException("未知资源类型");};}
    JsonObject get(String path,Map<String,String> query)throws IOException{
        StringBuilder url=new StringBuilder("https://api.curseforge.com/v1"+path);if(!query.isEmpty()){url.append('?');for(var item:query.entrySet())url.append(URLEncoder.encode(item.getKey(),StandardCharsets.UTF_8)).append('=').append(URLEncoder.encode(item.getValue(),StandardCharsets.UTF_8)).append('&');}
        IOException failure=null;for(URI candidate:provider.injectURLWithCandidates(url.toString())){
            HttpURLConnection connection=null;try{connection=(HttpURLConnection)candidate.toURL().openConnection();connection.setConnectTimeout(9000);connection.setReadTimeout(18000);connection.setRequestProperty("Accept","application/json");connection.setRequestProperty("User-Agent","MC-harbor/1.2");if("api.curseforge.com".equalsIgnoreCase(candidate.getHost())&&!CurseForgeRemoteAddonRepository.API_KEY.isBlank())connection.setRequestProperty("x-api-key",CurseForgeRemoteAddonRepository.API_KEY);
                int status=connection.getResponseCode();if(status!=200)throw new IOException("CurseForge 暂不可用（HTTP "+status+"）");byte[] bytes;try(InputStream stream=connection.getInputStream()){bytes=stream.readNBytes(24_000_001);}if(bytes.length>24_000_000)throw new IOException("资源平台响应过大");return JsonParser.parseString(new String(bytes,StandardCharsets.UTF_8)).getAsJsonObject();
            }catch(IOException e){failure=e;}catch(RuntimeException e){failure=new IOException("无法解析 CurseForge 返回的数据",e);}finally{if(connection!=null)connection.disconnect();}
        }throw failure!=null?failure:new IOException("CurseForge 没有可用来源");
    }
    private static String numeric(String value)throws IOException{String id=value.replaceFirst("^cf-","").replaceFirst("^file-","");if(!id.matches("[0-9]{1,15}"))throw new IOException("资源编号无效");return id;}
    Map<String,Object> search()throws IOException{
        int page=Math.max(0,input.has("page")?input.get("page").getAsInt():0);Map<String,String> query=new LinkedHashMap<>(Map.of("gameId","432","classId",Integer.toString(section()),"searchFilter",text("query",""),"sortField",text("query","").isEmpty()?"6":"8","sortOrder","desc","pageSize","30","index",Integer.toString(page*30)));
        if(!text("version","").isEmpty())query.put("gameVersion",text("version",""));if(section()==6&&loader()>0)query.put("modLoaderType",Integer.toString(loader()));JsonObject response=get("/mods/search",query);List<Map<String,Object>> hits=new ArrayList<>();
        for(JsonElement entry:array(response,"data")){JsonObject project=entry.getAsJsonObject();Map<String,Object> item=new LinkedHashMap<>();item.put("projectId","cf-"+project.get("id").getAsString());item.put("title",string(project,"name",""));item.put("description",string(project,"summary",""));item.put("author",String.join(", ",java.util.stream.StreamSupport.stream(array(project,"authors").spliterator(),false).map(a->string(a.getAsJsonObject(),"name","")).toList()));item.put("iconUrl",project.has("logo")&&!project.get("logo").isJsonNull()?string(project.getAsJsonObject("logo"),"thumbnailUrl",null):null);item.put("downloads",number(project,"downloadCount",0));item.put("pageUrl",project.has("links")?string(project.getAsJsonObject("links"),"websiteUrl",null):null);hits.add(item);}
        JsonObject pagination=response.getAsJsonObject("pagination");int total=pagination==null?hits.size():(int)number(pagination,"totalCount",hits.size());return Map.of("hits",hits,"totalHits",total);
    }
    List<JsonObject> files(String id)throws IOException{Map<String,String> query=new LinkedHashMap<>(Map.of("pageSize","50"));if(!text("version","").isEmpty())query.put("gameVersion",text("version",""));if(section()==6&&loader()>0)query.put("modLoaderType",Integer.toString(loader()));List<JsonObject> files=new ArrayList<>();for(JsonElement file:array(get("/mods/"+numeric(id)+"/files",query),"data")){JsonObject object=file.getAsJsonObject();if(!object.has("isAvailable")||object.get("isAvailable").getAsBoolean())files.add(object);}return files;}
    Map<String,Object> version(String project,JsonObject file,boolean requireURL)throws IOException{
        String address=string(file,"downloadUrl","");if(address.isEmpty()&&requireURL){try{address=get("/mods/"+numeric(project)+"/files/"+file.get("id").getAsString()+"/download-url",Map.of()).get("data").getAsString();}catch(Exception ignored){}if(address.isEmpty())throw new IOException("作者未开放此文件的第三方直接下载，请在 CurseForge 页面下载后导入。");}
        List<String> games=new ArrayList<>(),loaders=new ArrayList<>();for(JsonElement value:array(file,"gameVersions")){String name=value.getAsString();games.add(name);switch(name.toLowerCase(Locale.ROOT)){case "forge","fabric","quilt","neoforge"->loaders.add(name.toLowerCase(Locale.ROOT));default->{}}}
        Map<String,String> hashes=new HashMap<>();for(JsonElement value:array(file,"hashes")){JsonObject hash=value.getAsJsonObject();int algorithm=hash.get("algo").getAsInt();if(algorithm==1)hashes.put("sha1",hash.get("value").getAsString());else if(algorithm==2)hashes.put("md5",hash.get("value").getAsString());}
        List<Map<String,Object>> dependencies=new ArrayList<>();for(JsonElement value:array(file,"dependencies")){JsonObject dependency=value.getAsJsonObject();dependencies.add(Map.of("projectId","cf-"+dependency.get("modId").getAsString(),"dependencyType",dependency.get("relationType").getAsInt()==3?"required":"optional"));}
        Map<String,Object> result=new LinkedHashMap<>();result.put("id","file-"+file.get("id").getAsString());result.put("projectId","cf-"+numeric(project));result.put("name",string(file,"displayName",""));result.put("versionNumber",string(file,"displayName",""));result.put("gameVersions",games);result.put("loaders",loaders);result.put("dependencies",dependencies);result.put("files",address.isEmpty()?List.of():List.of(Map.of("filename",string(file,"fileName",""),"url",address,"size",number(file,"fileLength",0),"hashes",hashes,"primary",true)));return result;
    }
    Map<String,Object> versions()throws IOException{String project=numeric(text("project",""));List<Map<String,Object>> versions=new ArrayList<>();for(JsonObject file:files(project))versions.add(version(project,file,false));return Map.of("versions",versions);}
    Map<String,Object> plan()throws IOException{List<Map<String,Object>> result=new ArrayList<>();visit(numeric(text("project","")),get("/mods/"+numeric(text("project",""))+"/files/"+numeric(text("file","")),Map.of()).getAsJsonObject("data"),new HashSet<>(),result);return Map.of("versions",result);}
    private void visit(String project,JsonObject file,Set<String> seen,List<Map<String,Object>> output)throws IOException{
        if(!seen.add(project))return;if(seen.size()>40)throw new IOException("必要依赖超过本次安装上限");if(!text("version","").isEmpty()&&java.util.stream.StreamSupport.stream(array(file,"gameVersions").spliterator(),false).noneMatch(v->v.getAsString().equals(text("version",""))))throw new IOException("文件与实例的 Minecraft 版本不兼容");
        if(section()==6){for(JsonElement value:array(file,"dependencies")){JsonObject dependency=value.getAsJsonObject();if(dependency.get("relationType").getAsInt()!=3)continue;String id=dependency.get("modId").getAsString();List<JsonObject> choices=files(id);if(choices.isEmpty())throw new IOException("必要依赖没有兼容版本："+id);visit(id,choices.get(0),seen,output);}}
        output.add(version(project,file,true));
    }
}
