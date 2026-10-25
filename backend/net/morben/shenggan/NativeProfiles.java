package net.morben.shenggan;

import org.jackhuang.hmcl.auth.Account;
import org.jackhuang.hmcl.auth.microsoft.MicrosoftAccount;
import org.jackhuang.hmcl.auth.yggdrasil.*;
import org.jackhuang.hmcl.auth.offline.OfflineAccount;
import org.jackhuang.hmcl.auth.offline.Skin;
import java.io.*;
import java.net.*;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import javax.imageio.ImageIO;

/** Resolves real HMCL/Mojang skin textures; never builds or substitutes a character model. */
final class NativeProfiles {
    static Map<String,Object> describe(Account account,Path data,boolean refresh)throws Exception {
        Path cache=data.resolve("skins");Files.createDirectories(cache);
        Map<String,Object> result=new LinkedHashMap<>();result.put("name",account.getProfileName());result.put("uuid",account.getProfileID().toString());result.put("canUpload",account.canUploadSkin());result.put("model","default");result.put("isDefault",false);
        Path skin=null,cape=null;
        if(account instanceof OfflineAccount offline){
            Skin selected=offline.getSkin();
            if(selected!=null){
                result.put("model",selected.textureModel()==TextureModel.SLIM?"slim":"default");
                if(selected.type()==Skin.Type.LOCAL_FILE){if(selected.localSkinPath()!=null)skin=Path.of(selected.localSkinPath());if(selected.localCapePath()!=null&&!selected.localCapePath().isBlank())cape=Path.of(selected.localCapePath());}
                else if(selected.type()!=Skin.Type.DEFAULT){String resource="/assets/img/skin/"+(selected.textureModel()==TextureModel.SLIM?"slim/":"wide/")+selected.type().name().toLowerCase(Locale.ROOT)+".png";skin=resource(resource,cache);}
            }
        }else{
            Optional<Map<TextureType,Texture>> textures=Optional.empty();
            if(account instanceof MicrosoftAccount microsoft){var repository=microsoft.getService().getProfileRepository();if(refresh)repository.invalidate(account.getProfileID());var profile=repository.getDirectly(account.getProfileID());if(profile.isPresent())textures=YggdrasilService.getTextures(profile.get());}
            else if(account instanceof YggdrasilAccount yggdrasil){var repository=yggdrasil.getYggdrasilService().getProfileRepository();if(refresh)repository.invalidate(account.getProfileID());var profile=repository.getDirectly(account.getProfileID());if(profile.isPresent())textures=YggdrasilService.getTextures(profile.get());}
            if(textures.isPresent()){
                Texture texture=textures.get().get(TextureType.SKIN);if(texture!=null&&texture.url()!=null){skin=download(texture.url(),cache,refresh);if(texture.metadata()!=null&&"slim".equals(texture.metadata().get("model")))result.put("model","slim");}
                Texture capeTexture=textures.get().get(TextureType.CAPE);if(capeTexture!=null&&capeTexture.url()!=null){try{cape=download(capeTexture.url(),cache,refresh);}catch(IOException ignored){}}
            }
        }
        if(skin==null||!Files.isRegularFile(skin)){skin=resource("/assets/img/skin/wide/steve.png",cache);result.put("isDefault",true);}
        if(skin==null)throw new IOException("默认 Minecraft 皮肤资源缺失");
        validate(skin,false);result.put("skinPath",skin.toAbsolutePath().toString());if(cape!=null&&Files.isRegularFile(cape))result.put("capePath",cape.toAbsolutePath().toString());return result;
    }
    static Map<String,Object> apply(Account account,Path selected,boolean slim,Path data)throws Exception {
        validate(selected,true);Path folder=data.resolve("skins");Files.createDirectories(folder);String hash=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(selected)));Path persistent=folder.resolve(hash+".png");if(!Files.exists(persistent))Files.copy(selected,persistent);
        if(account instanceof OfflineAccount offline){offline.setSkin(new Skin(Skin.Type.LOCAL_FILE,null,slim?TextureModel.SLIM:TextureModel.WIDE,persistent.toString(),null));}
        else{if(!account.canUploadSkin())throw new IOException("此账号服务不支持皮肤上传");account.logIn();account.uploadSkin(slim,persistent);}
        return new LinkedHashMap<>(Map.of("name",account.getProfileName(),"uuid",account.getProfileID().toString(),"canUpload",account.canUploadSkin(),"model",slim?"slim":"default","isDefault",false,"skinPath",persistent.toString(),"applied",true));
    }
    static void validate(Path file,boolean upload)throws IOException {
        if(!Files.isRegularFile(file)||Files.size(file)>4_000_000)throw new IOException("请选择不超过 4 MB 的 Minecraft PNG 皮肤");
        byte[] header;try(InputStream input=Files.newInputStream(file)){header=input.readNBytes(24);}if(header.length<24||header[0]!=(byte)0x89||header[1]!='P'||header[2]!='N'||header[3]!='G')throw new IOException("皮肤必须是 PNG 文件");
        int width=java.nio.ByteBuffer.wrap(header,16,4).getInt(),height=java.nio.ByteBuffer.wrap(header,20,4).getInt();
        if(upload?(width!=64||(height!=64&&height!=32)):(width<64||width>2048||(height!=width&&height*2!=width)))throw new IOException(upload?"上传皮肤需为 64×64 或 64×32 PNG":"Minecraft 皮肤尺寸无效");
        if(ImageIO.read(file.toFile())==null)throw new IOException("无法解码皮肤 PNG");
    }
    private static Path resource(String name,Path cache)throws IOException {String filename=name.substring(name.lastIndexOf('/')+1);Path target=cache.resolve("default-"+(name.contains("/slim/")?"slim-":"wide-")+filename);if(!Files.exists(target)){try(InputStream input=NativeProfiles.class.getResourceAsStream(name)){if(input==null)return null;Files.copy(input,target);}}return target;}
    private static Path download(String address,Path cache,boolean refresh)throws Exception {
        URI uri=URI.create(address);if(!Set.of("http","https").contains(uri.getScheme()))throw new IOException("皮肤服务地址无效");
        String digest=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(address.getBytes(java.nio.charset.StandardCharsets.UTF_8)));Path target=cache.resolve(digest+".png");if(!refresh&&Files.isRegularFile(target))return target;
        HttpURLConnection connection=(HttpURLConnection)uri.toURL().openConnection();connection.setConnectTimeout(12000);connection.setReadTimeout(18000);try{if(connection.getResponseCode()!=200)throw new IOException("皮肤下载暂不可用");byte[] bytes;try(InputStream stream=connection.getInputStream()){bytes=stream.readNBytes(4_000_001);}if(bytes.length>4_000_000)throw new IOException("皮肤文件过大");Path stage=Files.createTempFile(cache,".skin-",".png");try{Files.write(stage,bytes);validate(stage,false);Files.move(stage,target,StandardCopyOption.REPLACE_EXISTING);}finally{Files.deleteIfExists(stage);}}finally{connection.disconnect();}return target;
    }
}
