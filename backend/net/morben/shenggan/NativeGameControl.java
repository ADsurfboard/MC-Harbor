package net.morben.shenggan;

import com.google.gson.Gson;
import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/** Supervises the exact game child independently of the native application. */
final class NativeGameControl implements AutoCloseable {
    private final Path runDirectory;
    private final Path stop;
    private final Path receipt;
    private final FileChannel channel;
    private final FileLock lock;

    NativeGameControl(Path data, Path runDirectory, String stopValue) throws Exception {
        this.runDirectory = runDirectory.toRealPath();
        stop = stopPath(data, stopValue);
        receipt = stop == null ? null :
                stop.resolveSibling(stop.getFileName().toString().replace(".stop", ".running"));
        Path root = data.resolve("launch-control");
        Files.createDirectories(root, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")));
        String key = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                .digest(this.runDirectory.toString().getBytes(StandardCharsets.UTF_8)));
        channel = FileChannel.open(root.resolve(key + ".lock"), StandardOpenOption.CREATE,
                StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
        try {
            lock = channel.tryLock();
            if (lock == null) throw new IOException("此游戏目录已有实例在启动或运行。");
        } catch (Exception error) {
            channel.close();
            throw error;
        }
    }

    static Path stopPath(Path data, String value) throws IOException {
        if (value == null || value.isBlank()) return null;
        Path root = data.resolve("launch-control").toAbsolutePath().normalize();
        Path stop = Path.of(value).toAbsolutePath().normalize();
        if (!root.equals(stop.getParent()) || !stop.getFileName().toString().matches("[a-fA-F0-9-]{36}\\.stop"))
            throw new IOException("无效的进程控制路径");
        return stop;
    }

    private boolean stopRequested() { return stop != null && Files.exists(stop, LinkOption.NOFOLLOW_LINKS); }

    void checkPendingStop() throws IOException {
        if (stopRequested()) throw new IOException("启动已取消。");
    }

    void record(String id, Process process) {
        if (receipt == null) return;
        long started = process.info().startInstant().map(Instant::toEpochMilli).orElse(0L);
        if (started == 0) return;
        try {
            Path temporary = Files.createTempFile(receipt.getParent(), "launch-", ".tmp",
                    PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
            try {
                Files.writeString(temporary, new Gson().toJson(Map.of(
                        "id", id, "runDirectory", runDirectory.toString(), "pid", process.pid(), "started", started)));
                Files.move(temporary, receipt, StandardCopyOption.ATOMIC_MOVE);
            } finally {
                Files.deleteIfExists(temporary);
            }
        } catch (IOException error) {
            System.err.println("Could not record running game state");
        }
    }

    int waitFor(Process process) throws InterruptedException {
        boolean requested = false;
        while (!process.waitFor(250, TimeUnit.MILLISECONDS)) {
            if (!requested && stopRequested()) {
                requested = true;
                process.destroy();
            }
        }
        return process.exitValue();
    }

    @Override public void close() throws IOException {
        try {
            if (receipt != null) Files.deleteIfExists(receipt);
            if (stop != null) Files.deleteIfExists(stop);
        } finally {
            try { lock.release(); }
            finally { channel.close(); }
        }
    }
}
