package net.morben.shenggan;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;

final class NativeWorldImport {
    static Map<String,Object> install(Path archive,Path run,String title)throws IOException{
        Path saves=run.resolve("saves").toAbsolutePath().normalize();Files.createDirectories(saves);Path stage=Files.createTempDirectory(saves,".harbor-world-");
        try(ZipFile zip=new ZipFile(archive.toFile())){
            List<? extends ZipEntry> entries=Collections.list(zip.entries());if(entries.size()>100_000)throw new IOException("地图压缩包文件过多");
            List<String> roots=new ArrayList<>();for(ZipEntry entry:entries){String name=entry.getName().replace('\\','/');if(name.contains("../")||name.startsWith("/")||name.matches("^[A-Za-z]:.*"))throw new IOException("地图压缩包包含不安全路径");if(name.equals("level.dat")||name.endsWith("/level.dat"))roots.add(name.substring(0,name.length()-"level.dat".length()));}
            if(roots.isEmpty())throw new IOException("未找到 Minecraft 地图的 level.dat");roots.sort(Comparator.comparingInt(String::length));String prefix=roots.get(0);if(roots.size()>1&&roots.get(1).length()==prefix.length())throw new IOException("压缩包包含多个地图，请分别导入对应的存档文件夹");
            long written=0;byte[] buffer=new byte[128*1024];for(ZipEntry entry:entries){String name=entry.getName().replace('\\','/');if(!name.startsWith(prefix))continue;String relative=name.substring(prefix.length());if(relative.isBlank()||relative.startsWith("__MACOSX/")||relative.endsWith(".DS_Store")||relative.endsWith("session.lock"))continue;Path target=stage.resolve(relative).normalize();if(!target.startsWith(stage))throw new IOException("地图路径越界");if(entry.isDirectory()){Files.createDirectories(target);continue;}if(entry.getSize()>0&&Files.getFileStore(saves).getUsableSpace()<entry.getSize()+32*1024*1024L)throw new IOException("没有足够空间解压地图");Files.createDirectories(target.getParent());CRC32 crc=new CRC32();long size=0;try(InputStream input=zip.getInputStream(entry);OutputStream output=Files.newOutputStream(target,StandardOpenOption.CREATE_NEW)){int count;while((count=input.read(buffer))>=0){size+=count;written+=count;if(written>8L*1024*1024*1024)throw new IOException("地图解压大小超过本次上限");crc.update(buffer,0,count);output.write(buffer,0,count);}}if((entry.getSize()>=0&&entry.getSize()!=size)||(entry.getCrc()>=0&&entry.getCrc()!=crc.getValue()))throw new IOException("地图压缩包 CRC 校验失败");}
            if(!Files.isRegularFile(stage.resolve("level.dat")))throw new IOException("地图结构无效");String name=title.replaceAll("[\\\\/:\\p{Cntrl}]","-").strip();if(name.isBlank())name="Minecraft 地图";if(name.length()>100)name=name.substring(0,100);Path destination=saves.resolve(name);int suffix=2;while(Files.exists(destination)){destination=saves.resolve(name+" ("+(suffix++)+")");}Files.move(stage,destination);return Map.of("path",destination.toString());
        }finally{if(Files.exists(stage)){try(var walk=Files.walk(stage)){for(Path file:walk.sorted(Comparator.reverseOrder()).toList())Files.deleteIfExists(file);}}}
    }
}
