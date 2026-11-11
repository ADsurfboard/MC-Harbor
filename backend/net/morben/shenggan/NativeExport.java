package net.morben.shenggan;
import com.google.gson.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;

/** The export whitelist also prevents accidental sharing of launcher secrets / caches. */
final class NativeExport {
    static final Map<String,Set<String>> GROUPS=Map.of(
        "mods",Set.of("mods"),"config",Set.of("config","defaultconfigs"),
        "options",Set.of("options.txt","optionsof.txt","optionsshaders.txt"),"servers",Set.of("servers.dat"),
        "resourcepacks",Set.of("resourcepacks"),"shaderpacks",Set.of("shaderpacks"),
        "scripts",Set.of("kubejs","scripts","patchouli_books"),"saves",Set.of("saves"));
    static Set<String> selected(JsonObject input)throws IOException {
        Set<String> keys=new HashSet<>(List.of("mods","config","options","resourcepacks","shaderpacks","scripts"));
        if(input.has("contents")){keys.clear();for(JsonElement e:input.getAsJsonArray("contents")){String k=e.getAsString();if(!GROUPS.containsKey(k))throw new IOException("未知导出内容："+k);keys.add(k);}}
        Set<String> paths=new HashSet<>();for(String key:keys)paths.addAll(GROUPS.get(key));return paths;
    }
    static boolean includes(String name,Set<String> selected){
        String normalized=name.replace('\\','/');if(!NativeResourceFiles.safe(normalized))return false;
        if(!normalized.startsWith(".minecraft/"))return true;
        String relative=normalized.substring(11);String top=relative.split("/",2)[0];return selected.contains(top)&&!relative.endsWith("session.lock");
    }
    static void filter(Path archive,JsonObject input)throws IOException {
        Set<String> selection=selected(input);Path stage=Files.createTempFile(archive.getParent(),".harbor-filter-",".partial");
        try{try(ZipFile zip=new ZipFile(archive.toFile());ZipOutputStream out=new ZipOutputStream(Files.newOutputStream(stage))){for(ZipEntry e:Collections.list(zip.entries())){if(e.isDirectory()||!includes(e.getName(),selection))continue;out.putNextEntry(new ZipEntry(e.getName()));try(InputStream stream=zip.getInputStream(e)){stream.transferTo(out);}out.closeEntry();}}Files.move(stage,archive,StandardCopyOption.REPLACE_EXISTING);}finally{Files.deleteIfExists(stage);}
    }
}
