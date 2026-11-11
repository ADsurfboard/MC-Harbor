package net.morben.shenggan;
import java.io.IOException;
import java.nio.file.*;
import java.util.concurrent.TimeUnit;

/** Only the Process object created by this launch can be stopped; never guesses a PID. */
final class NativeGameControl {
    static Path stopPath(Path data,String value)throws IOException{
        if(value==null||value.isBlank())return null;
        Path root=data.resolve("launch-control").toAbsolutePath().normalize();Path stop=Path.of(value).toAbsolutePath().normalize();
        if(!stop.getParent().equals(root)||!stop.getFileName().toString().matches("[a-fA-F0-9-]{36}\\.stop"))throw new IOException("无效的进程控制路径");return stop;
    }
    static int waitFor(Process process,Path stop)throws Exception{
        Thread cleanup=new Thread(()->{if(process.isAlive())process.destroy();});Runtime.getRuntime().addShutdownHook(cleanup);
        try{boolean requested=false;while(!process.waitFor(250,TimeUnit.MILLISECONDS)){if(!requested&&stop!=null&&Files.exists(stop,LinkOption.NOFOLLOW_LINKS)){requested=true;process.destroy();}}return process.exitValue();}
        finally{if(process.isAlive())process.destroy();try{Runtime.getRuntime().removeShutdownHook(cleanup);}catch(IllegalStateException ignored){}if(stop!=null)Files.deleteIfExists(stop);}
    }
}
