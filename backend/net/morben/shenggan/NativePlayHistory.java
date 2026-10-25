package net.morben.shenggan;

import com.google.gson.*;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;

/** The engine finishes this receipt even when the native window has been closed. */
final class NativePlayHistory implements AutoCloseable {
    private final Path directory, target;
    private final String id;
    private final long started=System.nanoTime();
    private final double epoch=Instant.now().toEpochMilli()/1000.0;
    private final long pid;
    private final Path run;
    private final ScheduledExecutorService timer=Executors.newSingleThreadScheduledExecutor(r->{Thread t=new Thread(r,"harbor-playtime");t.setDaemon(true);return t;});
    NativePlayHistory(Path data,String id,Path run,long pid)throws Exception{
        this.id=UUID.fromString(id).toString().toUpperCase(Locale.ROOT);this.run=run;this.pid=pid;
        directory=data.resolve("social/receipts");Files.createDirectories(directory);Files.setPosixFilePermissions(directory,PosixFilePermissions.fromString("rwx------"));target=directory.resolve(this.id+".json");
        write(false);timer.scheduleWithFixedDelay(()->{try{write(false);}catch(Exception e){System.err.println("Playtime receipt update failed");}},60,60,TimeUnit.SECONDS);
    }
    private String world(){try{Path saves=run.resolve("saves");if(!Files.isDirectory(saves))return "";try(var paths=Files.list(saves)){Path latest=null;long newest=(long)(epoch*1000)-2000;for(Path path:paths.toList()){Path level=path.resolve("level.dat");if(!Files.isRegularFile(level,LinkOption.NOFOLLOW_LINKS))continue;long modified=Files.getLastModifiedTime(level).toMillis();if(modified>newest){newest=modified;latest=path;}}return latest==null?"":latest.getFileName().toString();}}catch(Exception e){return "";}}
    private synchronized void write(boolean finished)throws Exception{
        Map<String,Object> value=Map.of("id",id,"started",epoch,"seconds",Math.max(0,(System.nanoTime()-started)/1_000_000_000.0),"finished",finished,"pid",pid,"world",finished?world():"");
        Path temporary=Files.createTempFile(directory,"receipt-",".tmp");try{Files.setPosixFilePermissions(temporary,PosixFilePermissions.fromString("rw-------"));Files.writeString(temporary,new Gson().toJson(value));try{Files.move(temporary,target,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);}catch(AtomicMoveNotSupportedException e){Files.move(temporary,target,StandardCopyOption.REPLACE_EXISTING);}}finally{Files.deleteIfExists(temporary);}
    }
    public void close(){timer.shutdownNow();try{write(true);}catch(Exception e){System.err.println("Playtime receipt finish failed");}}
}
