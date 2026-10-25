import com.sun.net.httpserver.HttpServer;
import org.jackhuang.hmcl.task.FileDownloadTask;
import org.jackhuang.hmcl.util.CacheRepository;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/** A local failure-injection check for the actual HMCL downloader and integrity verifier. */
public final class FailoverCheck {
    public static void main(String[] args)throws Exception{
        System.setProperty("shenggan.headless","true");Path directory=Path.of(args[0]);Files.createDirectories(directory);CacheRepository.getInstance().changeDirectory(directory);
        byte[] valid="Minecraft download fallback integrity fixture".getBytes(StandardCharsets.UTF_8);String hash=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-1").digest(valid));
        AtomicInteger failedHits=new AtomicInteger(),validHits=new AtomicInteger();HttpServer server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        server.createContext("/broken",exchange->{failedHits.incrementAndGet();byte[] bytes="corrupt-content".getBytes(StandardCharsets.UTF_8);exchange.sendResponseHeaders(200,bytes.length);exchange.getResponseBody().write(bytes);exchange.close();});
        server.createContext("/good",exchange->{validHits.incrementAndGet();exchange.sendResponseHeaders(200,valid.length);exchange.getResponseBody().write(valid);exchange.close();});server.start();
        String origin="http://127.0.0.1:"+server.getAddress().getPort();Path output=directory.resolve("verified.bin");
        boolean passed=false;
        try{var task=new FileDownloadTask(List.of(URI.create(origin+"/broken"),URI.create(origin+"/good")),output,new FileDownloadTask.IntegrityCheck("SHA-1",hash));boolean completed=task.executor().test();passed=completed&&failedHits.get()>0&&validHits.get()>0&&MessageDigest.isEqual(Files.readAllBytes(output),valid);System.out.println("{\"checksumRejectThenFallback\":"+passed+",\"badSourceRequests\":"+failedHits.get()+",\"goodSourceRequests\":"+validHits.get()+"}");}finally{server.stop(0);}
        System.exit(passed?0:1);
    }
}
