package net.morben.shenggan;

import com.google.gson.*;
import org.jackhuang.hmcl.util.versioning.VersionNumber;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.*;
import java.util.*;
import java.util.zip.*;

/** Consumes the official CFPA published packs and their MD5 manifests; no scraped translations. */
final class NativeCommunityLanguages {
    private static final List<String> SERVERS=List.of("https://bmclapi2.bangbang93.com/mirrors/i18n-update-mod/","https://i18dl.imc.wiki/");
    static Path resources(){try{return Path.of(NativeCommunityLanguages.class.getProtectionDomain().getCodeSource().getLocation().toURI()).getParent();}catch(Exception e){return Path.of(".");}}
    static Path asset(String name){Path folder=resources().resolve("Localization/"+name);return Files.isRegularFile(folder)?folder:resources().resolve("../Assets/Localization/"+name).normalize();}
    private static String text(JsonObject o,String key){return NativeResourceFiles.text(o,key,"");}
    private static String md5(Path path)throws Exception{MessageDigest digest=MessageDigest.getInstance("MD5");try(InputStream in=Files.newInputStream(path)){byte[] b=new byte[512*1024];for(int n;(n=in.read(b))>0;)digest.update(b,0,n);}return HexFormat.of().formatHex(digest.digest());}
    private static HttpURLConnection open(String address)throws IOException{HttpURLConnection c=(HttpURLConnection)URI.create(address).toURL().openConnection();c.setConnectTimeout(8000);c.setReadTimeout(18000);c.setRequestProperty("User-Agent","MC-harbor/1.3 CFPA language integration");if(c.getResponseCode()!=200){c.disconnect();throw new IOException("社区译库暂不可用");}return c;}
    static Path download(String version,String loader,Path data){
        Path target=null;
        try{
            JsonObject metadata=NativeResourceFiles.object(asset("i18n-metadata.json"));String packVersion="";for(JsonElement e:metadata.getAsJsonArray("games")){JsonObject game=e.getAsJsonObject();String range=text(game,"gameVersions");String[] limits=range.replace("[","").replace("]","").split(",");if(limits.length==2&&VersionNumber.compare(version,limits[0])>=0&&VersionNumber.compare(version,limits[1])<=0){packVersion=game.getAsJsonArray("convertFrom").get(0).getAsString();break;}}
            if(packVersion.isEmpty())return null;JsonObject selected=null;String desired=loader.equalsIgnoreCase("Fabric")||loader.equalsIgnoreCase("Quilt")||loader.equalsIgnoreCase("Legacy Fabric")?"Fabric":"Forge";
            for(JsonElement e:metadata.getAsJsonArray("assets")){JsonObject asset=e.getAsJsonObject();if(!text(asset,"targetVersion").equals(packVersion))continue;if(selected==null)selected=asset;if(text(asset,"loader").equalsIgnoreCase(desired)){selected=asset;break;}}
            if(selected==null)return null;String file=text(selected,"filename"),hashFile=text(selected,"md5Filename");if(!file.matches("[A-Za-z0-9_.-]+")||!hashFile.matches("[A-Za-z0-9_.-]+"))return null;
            Path cache=data.resolve("translation-cache");Files.createDirectories(cache);target=cache.resolve(file);Path localHash=cache.resolve(hashFile);
            if(Files.isRegularFile(target)&&Files.isRegularFile(localHash)&&md5(target).equalsIgnoreCase(Files.readString(localHash).trim())&&System.currentTimeMillis()-Files.getLastModifiedTime(localHash).toMillis()<86_400_000L)return target;
            for(String server:SERVERS){try{String expected;HttpURLConnection manifest=open(server+hashFile);try(InputStream in=manifest.getInputStream()){expected=new String(NativeResourceFiles.bounded(in,1024),StandardCharsets.UTF_8).trim();}finally{manifest.disconnect();}if(!expected.matches("[a-fA-F0-9]{32}"))continue;
                    if(Files.isRegularFile(target)&&md5(target).equalsIgnoreCase(expected)){Files.writeString(localHash,expected);return target;}
                    if(Files.getFileStore(cache).getUsableSpace()<192_000_000L)throw new IOException("社区译库下载所需磁盘空间不足");Path stage=Files.createTempFile(cache,"community-",".zip");
                    try{HttpURLConnection c=open(server+file);try(InputStream in=c.getInputStream();OutputStream out=Files.newOutputStream(stage)){byte[] b=new byte[128*1024];long total=0;for(int n;(n=in.read(b))>0;){total+=n;if(total>128_000_000)throw new IOException("社区译库超过下载上限");out.write(b,0,n);}}finally{c.disconnect();}if(!md5(stage).equalsIgnoreCase(expected))throw new IOException("社区译库 MD5 校验失败");try(ZipFile zip=new ZipFile(stage.toFile())){long size=0;for(ZipEntry entry:Collections.list(zip.entries())){if(!NativeResourceFiles.safe(entry.getName()))throw new IOException("社区译库包含无效路径");size+=Math.max(0,entry.getSize());if(size>256_000_000L)throw new IOException("社区译库展开量过大");}}Files.move(stage,target,StandardCopyOption.REPLACE_EXISTING);Files.writeString(localHash,expected);return target;}finally{Files.deleteIfExists(stage);}
                }catch(Exception ignored){}}
        }catch(Exception ignored){}
        if(target!=null&&Files.isRegularFile(target))try{String file=target.getFileName().toString();JsonObject metadata=NativeResourceFiles.object(asset("i18n-metadata.json"));for(JsonElement e:metadata.getAsJsonArray("assets")){JsonObject a=e.getAsJsonObject();Path hash=data.resolve("translation-cache/"+text(a,"md5Filename"));if(text(a,"filename").equals(file)&&Files.isRegularFile(hash)&&md5(target).equalsIgnoreCase(Files.readString(hash).trim()))return target;}}catch(Exception ignored){}
        return null;
    }
}
