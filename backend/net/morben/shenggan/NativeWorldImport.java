package net.morben.shenggan;

import java.io.*;
import java.nio.file.*;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.*;
import java.util.zip.*;

final class NativeWorldImport {
    private static final boolean WINDOWS = File.separatorChar == '\\';
    private static final long MAX_WORLD_BYTES = 8L * 1024 * 1024 * 1024;

    static Map<String, Object> install(Path archive, Path run, String title) throws IOException {
        Path saves = run.resolve("saves").toAbsolutePath().normalize();
        try (ZipFile zip = new ZipFile(archive.toFile())) {
            if (zip.size() > 100_000) throw new IOException("地图压缩包文件过多");
            List<WorldEntry> entries = new ArrayList<>();
            for (ZipEntry entry : Collections.list(zip.entries())) {
                String name = entry.getName().replace('\\', '/');
                if (!NativeResourceFiles.safe(name) || name.matches("^[A-Za-z]:.*"))
                    throw new IOException("地图压缩包包含不安全路径");
                if (!name.startsWith("__MACOSX/"))
                    entries.add(new WorldEntry(entry, name, entry.isDirectory() || name.endsWith("/")));
            }
            String prefix = worldPrefix(entries);
            List<WorldEntry> world = selectedEntries(entries, prefix);
            checkTargetDirectory(saves);
            Files.createDirectories(saves);
            Path stage = Files.createTempDirectory(saves, ".harbor-world-");
            try {
                long available = Math.max(0L, Files.getFileStore(saves).getUsableSpace() - 32L * 1024 * 1024);
                long limit = Math.min(available, MAX_WORLD_BYTES);
                long written = 0;
                byte[] buffer = new byte[128 * 1024];
                for (WorldEntry entry : world) {
                    Path target = stage.resolve(entry.name());
                    if (entry.directory()) {
                        Files.createDirectories(target);
                        continue;
                    }
                    Files.createDirectories(target.getParent());
                    written += extract(zip, entry.zipEntry(), target, buffer, limit - written);
                }
                if (!Files.isRegularFile(stage.resolve("level.dat"))) throw new IOException("地图结构无效");
                return Map.of("path", commit(stage, saves, title).toString());
            } finally {
                if (Files.exists(stage)) {
                    try (var walk = Files.walk(stage)) {
                        for (Path file : walk.sorted(Comparator.reverseOrder()).toList())
                            Files.deleteIfExists(file);
                    }
                }
            }
        }
    }

    private static String worldPrefix(List<WorldEntry> entries) throws IOException {
        var roots = entries.stream().filter(entry -> !entry.directory())
                .map(WorldEntry::name).filter(name -> name.equals("level.dat") || name.endsWith("/level.dat"))
                .map(name -> name.substring(0, name.length() - "level.dat".length())).sorted().toList();
        if (roots.isEmpty()) throw new IOException("未找到 Minecraft 地图的 level.dat");
        String prefix = roots.get(0);
        if (roots.stream().anyMatch(root -> !root.startsWith(prefix)))
            throw new IOException("压缩包包含多个地图，请分别导入对应的存档文件夹");
        return prefix;
    }

    private static List<WorldEntry> selectedEntries(List<WorldEntry> entries, String prefix) throws IOException {
        List<WorldEntry> result = new ArrayList<>();
        Map<String, String> spelling = new HashMap<>();
        Set<String> files = new HashSet<>();
        Set<String> explicit = new HashSet<>();
        for (WorldEntry entry : entries) {
            if (!entry.name().startsWith(prefix)) continue;
            String relative = entry.name().substring(prefix.length());
            if (relative.endsWith("/")) relative = relative.substring(0, relative.length() - 1);
            if (relative.isEmpty()) continue;
            String leaf = relative.substring(relative.lastIndexOf('/') + 1);
            if (leaf.equals(".DS_Store") || leaf.equals("session.lock") || leaf.startsWith("._")) continue;
            if (!NativeResourceFiles.safe(relative)) throw new IOException("地图包含无效文件名");
            String key = WINDOWS ? relative.toLowerCase(Locale.ROOT) : relative;
            if (!explicit.add(key) || files.contains(key) || (!entry.directory() && spelling.containsKey(key)))
                throw new IOException("地图压缩包含有重复或冲突的路径");
            if (!entry.directory()) files.add(key);
            String part = relative;
            for (;;) {
                String folded = WINDOWS ? part.toLowerCase(Locale.ROOT) : part;
                String previous = spelling.putIfAbsent(folded, part);
                if (previous != null && !previous.equals(part)) throw new IOException("地图路径的大小写冲突");
                int slash = part.lastIndexOf('/');
                if (slash < 0) break;
                part = part.substring(0, slash);
                String parentKey = WINDOWS ? part.toLowerCase(Locale.ROOT) : part;
                if (files.contains(parentKey)) throw new IOException("地图中的文件与目录同名");
            }
            result.add(new WorldEntry(entry.zipEntry(), relative, entry.directory()));
        }
        return result;
    }

    private static void checkTargetDirectory(Path target) throws IOException {
        for (Path directory = target; directory != null; directory = directory.getParent()) {
            try {
                var attributes = Files.readAttributes(directory, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
                if (!attributes.isDirectory() || attributes.isOther() || attributes.isSymbolicLink())
                    throw new IOException("地图目标路径包含链接或普通文件");
            } catch (NoSuchFileException ignored) { }
        }
    }

    private static long extract(ZipFile zip, ZipEntry entry, Path target, byte[] buffer, long limit) throws IOException {
        if (entry.getSize() > limit) throw new IOException("地图解压空间不足或超过大小限制");
        CRC32 crc = new CRC32();
        long size = 0;
        try (InputStream input = zip.getInputStream(entry);
             OutputStream output = Files.newOutputStream(target, StandardOpenOption.CREATE_NEW)) {
            for (int count; (count = input.read(buffer)) != -1;) {
                size += count;
                if (size > limit) throw new IOException("地图解压空间不足或超过大小限制");
                crc.update(buffer, 0, count);
                output.write(buffer, 0, count);
            }
        }
        if (size != entry.getSize() || crc.getValue() != entry.getCrc())
            throw new IOException("地图压缩包 CRC 校验失败");
        return size;
    }

    private static Path commit(Path stage, Path saves, String title) throws IOException {
        String name = title.replaceAll("[\\\\/<>:\"|?*\\p{Cntrl}]", "-").strip().replaceFirst("[ .]+$", "");
        if (name.isBlank()) name = "Minecraft 地图";
        if (name.codePointCount(0, name.length()) > 100) name = name.substring(0, name.offsetByCodePoints(0, 100));
        name = name.replaceFirst("[ .]+$", "");
        if (!NativeResourceFiles.safe(name)) name = "地图 " + name;
        int suffix = 1;
        while (true) {
            Path destination = saves.resolve(suffix == 1 ? name : name + " (" + suffix + ")");
            try { return Files.move(stage, destination); }
            catch (FileAlreadyExistsException error) { suffix++; }
        }
    }

    private record WorldEntry(ZipEntry zipEntry, String name, boolean directory) { }
}
