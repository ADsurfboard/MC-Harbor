package net.morben.shenggan;

import com.google.gson.*;
import org.glavo.nbt.io.NBTCodec;
import org.glavo.nbt.tag.*;

import java.io.*;
import java.nio.channels.*;
import java.nio.file.*;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;
import java.util.zip.*;

/** Edits existing Java-world NBT through HMCL's bundled codec, preserving all unrelated tags. */
final class NativeWorldEditor {
    private final JsonObject request;
    private final Path appData;
    private static final int MAX_COMPRESSED = 16 * 1024 * 1024;
    private static final int MAX_EXPANDED = 64 * 1024 * 1024;
    private static final NBTCodec CODEC = NBTCodec.of();

    NativeWorldEditor(JsonObject request, Path appData) { this.request = request; this.appData = appData; }

    Map<String, Object> read() throws Exception {
        Path world = world();
        try (WorldLock ignored = lock(world)) { return snapshot(world).describe(); }
    }

    Map<String, Object> save() throws Exception {
        Path world = world();
        try (WorldLock ignored = lock(world)) {
            Snapshot before = snapshot(world);
            if (!before.revision().equals(text("revision", "")))
                throw new IOException("存档已被游戏或其他程序更新，请重新读取后再编辑。");
            JsonObject changes = request.getAsJsonObject("changes");
            if (changes == null || changes.isEmpty()) throw new IOException("没有需要保存的修改。");
            Set<String> allowed = Set.of("name", "gameMode", "difficulty", "hardcore", "cheats", "day", "dayTick", "ageTicks", "health", "hunger", "saturation", "xpLevel", "xpProgress");
            for (String key : changes.keySet()) if (!allowed.contains(key)) throw new IOException("不支持的编辑项：" + key);
            CompoundTag data = before.data();
            if (changes.has("name")) {
                String name = changes.get("name").getAsString().strip();
                if (name.isEmpty() || name.length() > 256) throw new IOException("存档名称须为 1–256 个字符。");
                if (!(data.get("LevelName") instanceof StringTag)) throw unsupported("存档名称");
                data.setString("LevelName", name);
            }
            setNumber(data, "GameType", changes, "gameMode", 0, 3, true);
            setNumber(data, "Difficulty", changes, "difficulty", 0, 3, true);
            setNumber(data, "hardcore", changes, "hardcore", 0, 1, true);
            setNumber(data, "allowCommands", changes, "cheats", 0, 1, true);
            setNumber(data, "Time", changes, "ageTicks", 0, 9_007_199_254_740_991L, true);
            if (changes.has("day") || changes.has("dayTick")) {
                long old = number(data.get("DayTime"), "游戏天数").longValue();
                long day = changes.has("day") ? integer(changes, "day", 0, 375_299_968_945L) : Math.floorDiv(old, 24000);
                long tick = changes.has("dayTick") ? integer(changes, "dayTick", 0, 23999) : Math.floorMod(old, 24000);
                long combined = Math.addExact(Math.multiplyExact(day, 24000), tick);
                if (combined > 9_007_199_254_740_991L) throw new IOException("天数超出可编辑范围。");
                writeNumber(data, "DayTime", combined);
            }
            boolean playerChange = changes.keySet().stream().anyMatch(k -> Set.of("health", "hunger", "saturation", "xpLevel", "xpProgress").contains(k));
            if (playerChange && before.player == null) throw new IOException("此存档还没有所选玩家的数据，请先进入游戏保存一次。");
            if (before.player != null) {
                for (CompoundTag player : before.playerCopies()) {
                    setNumber(player, "Health", changes, "health", 0, 1_000_000, false);
                    setNumber(player, "foodLevel", changes, "hunger", 0, 20, true);
                    setNumber(player, "foodSaturationLevel", changes, "saturation", 0, 20, false);
                    if (changes.has("xpLevel") || changes.has("xpProgress")) {
                        int level = changes.has("xpLevel") ? (int) integer(changes, "xpLevel", 0, 21863) : number(player.get("XpLevel"), "经验等级").intValue();
                        double progress = changes.has("xpProgress") ? decimal(changes, "xpProgress", 0, 0.999999) : number(player.get("XpP"), "经验进度").doubleValue();
                        double total = xpBefore(level) + Math.floor(xpNext(level) * progress);
                        if (total > Integer.MAX_VALUE) throw new IOException("经验总量超出 Minecraft 的整数范围。");
                        writeNumber(player, "XpLevel", level);
                        writeNumber(player, "XpP", progress);
                        if (player.get("XpTotal") != null) writeNumber(player, "XpTotal", total);
                    }
                    if (changes.has("gameMode")) {
                        int mode = (int) integer(changes, "gameMode", 0, 3);
                        if (player.get("playerGameType") != null) writeNumber(player, "playerGameType", mode);
                        if (player.get("abilities") instanceof CompoundTag abilities) {
                            ability(abilities, "mayfly", mode == 1 || mode == 3);
                            ability(abilities, "invulnerable", mode == 1 || mode == 3);
                            ability(abilities, "instabuild", mode == 1);
                            ability(abilities, "mayBuild", mode != 3);
                            if (mode != 1) ability(abilities, "flying", mode == 3);
                        }
                    }
                }
            }
            LinkedHashMap<Path, byte[]> writes = new LinkedHashMap<>();
            for (Document doc : before.documents()) {
                byte[] updated = doc.encode();
                CompoundTag roundTrip = decode(updated);
                if (!doc.root.contentEquals(roundTrip)) throw new IOException("存档序列化校验失败，原文件未改动。");
                writes.put(doc.path, updated);
            }
            // A byte-exact backup is completed before any metadata file becomes visible.
            Path backup = backup(world, before);
            commit(world, before, writes);
            Map<String, Object> output = new LinkedHashMap<>(snapshot(world).describe());
            output.put("backup", backup.toString());
            return output;
        }
    }

    private Snapshot snapshot(Path world) throws Exception {
        Document level = load(world.resolve(Files.exists(world.resolve("level.dat")) ? "level.dat" : "special_level.dat"));
        if (!(level.root.get("Data") instanceof CompoundTag data)) throw new IOException("无法识别此存档的 Data 结构。");
        List<Player> players = new ArrayList<>();
        if (data.get("Player") instanceof CompoundTag local) players.add(new Player("local", "本地玩家", local, null));
        for (String folder : List.of("playerdata", "players/data", "players")) {
            Path dir = world.resolve(folder);
            if (!Files.isDirectory(dir, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(dir)) continue;
            try (var stream = Files.list(dir)) {
                for (Path file : stream.filter(p -> p.getFileName().toString().matches("[A-Za-z0-9_-]{1,64}\\.dat")).sorted().limit(256).toList()) {
                    if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS) || !file.toRealPath().startsWith(world)) continue;
                    String id = world.relativize(file).toString().replace(File.separatorChar, '/');
                    players.add(new Player(id, file.getFileName().toString().replaceFirst("\\.dat$", ""), null, file));
                }
            }
        }
        String selected = text("player", "");
        if (selected.isEmpty()) {
            selected = "local";
            if (data.get("singleplayer_uuid") instanceof IntArrayTag uuid && uuid.isUUID()) {
                String wanted = "players/data/" + uuid.getUUID() + ".dat";
                if (players.stream().anyMatch(p -> p.id.equals(wanted))) selected = wanted;
            }
            String candidate = selected;
            if (players.stream().noneMatch(p -> p.id.equals(candidate))) selected = players.isEmpty() ? "" : players.get(0).id;
        }
        String selection = selected;
        Player chosen = players.stream().filter(p -> p.id.equals(selection)).findFirst().orElse(null);
        if (!selected.isEmpty() && chosen == null) throw new IOException("所选玩家数据已不存在，请重新读取。");
        Document external = chosen != null && chosen.path != null ? load(chosen.path) : null;
        CompoundTag player = chosen == null ? null : external == null ? chosen.tag : external.root;
        Document mirror = null;
        // The embedded host and its UUID file represent one player. Keep their edited fields aligned.
        if (chosen != null && chosen.id.equals("local")) {
            UUID uuid = playerUUID(player);
            if (uuid != null) {
                Path file = world.resolve("playerdata/" + uuid + ".dat");
                if (Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS) && file.toRealPath().startsWith(world)) mirror = load(file);
            }
        }
        if (external != null && data.get("Player") instanceof CompoundTag local) {
            UUID uuid = playerUUID(local), other = playerUUID(player);
            if (uuid != null && uuid.equals(other)) chosen = new Player(chosen.id, chosen.label, local, chosen.path);
        }
        return new Snapshot(world, level, data, players, chosen, player, external, mirror);
    }

    private final class Snapshot {
        final Path world; final Document level; final CompoundTag data; final List<Player> players;
        final Player chosen; final CompoundTag player; final Document external; final Document mirror;
        Snapshot(Path world, Document level, CompoundTag data, List<Player> players, Player chosen, CompoundTag player, Document external, Document mirror) {
            this.world=world;this.level=level;this.data=data;this.players=players;this.chosen=chosen;this.player=player;this.external=external;this.mirror=mirror;
        }
        CompoundTag data() { return data; }
        List<Document> documents() { List<Document> docs=new ArrayList<>();docs.add(level);if(external!=null)docs.add(external);if(mirror!=null)docs.add(mirror);return docs; }
        List<CompoundTag> playerCopies() {
            List<CompoundTag> copies=new ArrayList<>();copies.add(player);
            if (mirror!=null) copies.add(mirror.root);
            if (external!=null && chosen.tag!=null && chosen.tag!=player) copies.add(chosen.tag);
            return copies;
        }
        String revision() throws Exception {
            MessageDigest hash=MessageDigest.getInstance("SHA-256");
            for(Document d:documents()){hash.update(world.relativize(d.path).toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));hash.update((byte)0);hash.update(d.bytes);}
            return HexFormat.of().formatHex(hash.digest());
        }
        Map<String,Object> describe() throws Exception {
            Map<String,Object> out=new LinkedHashMap<>(), values=new LinkedHashMap<>();
            out.put("revision",revision());out.put("world",world.getFileName().toString());out.put("player",chosen==null?"":chosen.id);
            out.put("players",players.stream().map(p->Map.of("id",p.id,"label",p.label)).toList());
            out.put("version",data.get("Version") instanceof CompoundTag v && v.get("Name") instanceof StringTag s?s.get():"未知版本");
            if(data.get("LevelName") instanceof StringTag s)values.put("name",s.get());
            expose(values,data,"GameType","gameMode");expose(values,data,"Difficulty","difficulty");expose(values,data,"hardcore","hardcore");expose(values,data,"allowCommands","cheats");expose(values,data,"Time","ageTicks");
            if(data.get("DayTime")!=null){long ticks=number(data.get("DayTime"),"游戏天数").longValue();if(ticks>=0){values.put("day",ticks/24000);values.put("dayTick",ticks%24000);}}
            if(player!=null){expose(values,player,"Health","health");expose(values,player,"foodLevel","hunger");expose(values,player,"foodSaturationLevel","saturation");expose(values,player,"XpLevel","xpLevel");expose(values,player,"XpP","xpProgress");expose(values,player,"XpTotal","xpTotal");expose(values,player,"playerGameType","playerGameMode");}
            out.put("values",values);return out;
        }
    }

    private Path world() throws IOException {
        String name=text("world","");
        if(name.isBlank()||name.equals(".")||name.equals("..")||name.contains("/")||name.contains("\\"))throw new IOException("无效的存档目录。");
        Path run=Path.of(text("runDirectory","")).toAbsolutePath().normalize().toRealPath();
        Path saves=run.resolve("saves");Path world=saves.resolve(name);
        if(Files.isSymbolicLink(saves)||Files.isSymbolicLink(world)||!Files.isDirectory(world,LinkOption.NOFOLLOW_LINKS)||!world.toRealPath().startsWith(run))throw new IOException("存档目录不在此实例中，或使用了符号链接。");
        return world.toRealPath();
    }

    private static final class WorldLock implements AutoCloseable {
        final FileChannel channel; final FileLock lock;
        WorldLock(FileChannel channel,FileLock lock){this.channel=channel;this.lock=lock;}
        public void close()throws IOException{try{lock.release();}finally{channel.close();}}
    }
    private static WorldLock lock(Path world)throws IOException{
        Path path=world.resolve("session.lock");
        if(Files.isSymbolicLink(path))throw new IOException("存档锁文件不能是符号链接。");
        FileChannel channel=FileChannel.open(path,StandardOpenOption.CREATE,StandardOpenOption.WRITE,LinkOption.NOFOLLOW_LINKS);
        try{FileLock lock=channel.tryLock();if(lock==null)throw new IOException("此存档正在游戏中使用，请退出世界后再编辑。");return new WorldLock(channel,lock);}
        catch(Exception e){channel.close();if(e instanceof IOException io)throw io;throw new IOException("无法取得存档锁，请退出世界后重试。",e);}
    }
    private record Player(String id,String label,CompoundTag tag,Path path){}
    private record Document(Path path,byte[] bytes,CompoundTag root,int compression){
        byte[] encode()throws IOException{
            byte[] raw=CODEC.writeTagToByteArray(root);
            if(compression==0)return raw;
            ByteArrayOutputStream bytes=new ByteArrayOutputStream();
            try(OutputStream zip=compression==1?new GZIPOutputStream(bytes):new DeflaterOutputStream(bytes)){zip.write(raw);}
            return bytes.toByteArray();
        }
    }
    private static int compression(byte[] bytes){return bytes.length>2&&bytes[0]==(byte)0x1f&&bytes[1]==(byte)0x8b?1:bytes.length>2&&bytes[0]==0x78?2:0;}
    private static Document load(Path path)throws IOException{
        if(!Files.isRegularFile(path,LinkOption.NOFOLLOW_LINKS)||Files.size(path)>MAX_COMPRESSED)throw new IOException("存档元数据文件无效或过大："+path.getFileName());
        byte[] bytes=Files.readAllBytes(path);return new Document(path,bytes,decode(bytes),compression(bytes));
    }
    private static CompoundTag decode(byte[] bytes)throws IOException{
        int kind=compression(bytes);
        try(InputStream input=kind==1?new GZIPInputStream(new ByteArrayInputStream(bytes)):kind==2?new InflaterInputStream(new ByteArrayInputStream(bytes)):new ByteArrayInputStream(bytes)){
            byte[] raw=input.readNBytes(MAX_EXPANDED+1);if(raw.length>MAX_EXPANDED)throw new IOException("解压后的存档元数据过大。");
            return CODEC.readTag(raw,TagType.COMPOUND);
        }
    }
    private Path backup(Path world,Snapshot before)throws Exception{
        Path base=appData.resolve("backups/world-edits");Files.createDirectories(base);
        Path path=base.resolve("world-"+Instant.now().toEpochMilli()+"-"+UUID.randomUUID()+".zip");
        try(ZipOutputStream zip=new ZipOutputStream(Files.newOutputStream(path,StandardOpenOption.CREATE_NEW))){
            for(Document d:before.documents()){zip.putNextEntry(new ZipEntry(world.relativize(d.path).toString().replace(File.separatorChar,'/')));zip.write(d.bytes);zip.closeEntry();}
            zip.putNextEntry(new ZipEntry("MC-Harbor-backup.json"));zip.write(("{\"format\":1,\"kind\":\"world-metadata-before-edit\",\"revision\":\""+before.revision()+"\"}").getBytes(java.nio.charset.StandardCharsets.UTF_8));zip.closeEntry();
        }
        try(ZipFile zip=new ZipFile(path.toFile())){for(Document d:before.documents()){String name=world.relativize(d.path).toString().replace(File.separatorChar,'/');if(!Arrays.equals(zip.getInputStream(zip.getEntry(name)).readAllBytes(),d.bytes))throw new IOException("存档备份校验失败，原文件未修改。");}}
        return path;
    }
    private static void commit(Path world,Snapshot before,LinkedHashMap<Path,byte[]> writes)throws Exception{
        LinkedHashMap<Path,Path> stage=new LinkedHashMap<>();List<Path> replaced=new ArrayList<>();
        try{
            for(var entry:writes.entrySet()){
                Path temp=Files.createTempFile(entry.getKey().getParent(),".harbor-world-",".dat");stage.put(entry.getKey(),temp);
                Files.write(temp,entry.getValue());try(FileChannel ch=FileChannel.open(temp,StandardOpenOption.WRITE)){ch.force(true);}
            }
            for(Document doc:before.documents())if(!Arrays.equals(Files.readAllBytes(doc.path),doc.bytes))throw new IOException("存档在保存期间发生变化，请重新读取。");
            for(var entry:stage.entrySet()){Files.move(entry.getValue(),entry.getKey(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);replaced.add(entry.getKey());}
        }catch(Exception failure){
            for(Path path:replaced){Document original=before.documents().stream().filter(d->d.path.equals(path)).findFirst().orElseThrow();Path temp=Files.createTempFile(path.getParent(),".harbor-rollback-",".dat");try{Files.write(temp,original.bytes);Files.move(temp,path,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);}catch(Exception rollback){failure.addSuppressed(rollback);}finally{Files.deleteIfExists(temp);}}
            throw failure;
        }finally{for(Path path:stage.values())Files.deleteIfExists(path);}
    }
    private static void expose(Map<String,Object> out,CompoundTag tag,String key,String target){try{Number n=number(tag.get(key),target);double value=n.doubleValue();if(Double.isFinite(value))out.put(target,n);}catch(IOException ignored){}}
    private static Number number(Tag tag,String label)throws IOException{
        if(tag instanceof ByteTag n)return n.get();if(tag instanceof ShortTag n)return n.get();if(tag instanceof IntTag n)return n.get();if(tag instanceof LongTag n)return n.get();if(tag instanceof FloatTag n)return n.get();if(tag instanceof DoubleTag n)return n.get();throw unsupported(label);
    }
    private static void writeNumber(CompoundTag tag,String key,double value)throws IOException{
        Tag old=tag.get(key);number(old,key);
        if(!Double.isFinite(value))throw new IOException("数值无效："+key);
        if(old instanceof ByteTag){if(value!=Math.rint(value)||value<Byte.MIN_VALUE||value>Byte.MAX_VALUE)throw unsupported(key);tag.setByte(key,(byte)value);}
        else if(old instanceof ShortTag){if(value!=Math.rint(value)||value<Short.MIN_VALUE||value>Short.MAX_VALUE)throw unsupported(key);tag.setShort(key,(short)value);}
        else if(old instanceof IntTag){if(value!=Math.rint(value)||value<Integer.MIN_VALUE||value>Integer.MAX_VALUE)throw unsupported(key);tag.setInt(key,(int)value);}
        else if(old instanceof LongTag)tag.setLong(key,(long)value);
        else if(old instanceof FloatTag)tag.setFloat(key,(float)value);else tag.setDouble(key,value);
    }
    private static void setNumber(CompoundTag target,String tag,JsonObject changes,String key,double min,double max,boolean whole)throws IOException{if(changes.has(key)){double value=decimal(changes,key,min,max);if(whole&&value!=Math.rint(value))throw new IOException("此项须填写整数："+key);writeNumber(target,tag,value);}}
    private static void ability(CompoundTag tag,String key,boolean value)throws IOException{if(tag.get(key)!=null)writeNumber(tag,key,value?1:0);}
    private static double decimal(JsonObject object,String key,double min,double max)throws IOException{try{double value=object.get(key).getAsDouble();if(!Double.isFinite(value)||value<min||value>max)throw new IllegalArgumentException();return value;}catch(Exception e){throw new IOException("数值超出范围或格式无效："+key);}}
    private static long integer(JsonObject object,String key,long min,long max)throws IOException{double value=decimal(object,key,min,max);if(value!=Math.rint(value))throw new IOException("此项须填写整数："+key);return(long)value;}
    private static IOException unsupported(String name){return new IOException("此版本没有可编辑的字段，或字段类型不受支持："+name);}
    private String text(String key,String fallback){return request.has(key)&&!request.get(key).isJsonNull()?request.get(key).getAsString():fallback;}
    private static UUID playerUUID(CompoundTag tag){if(tag.get("UUID") instanceof IntArrayTag uuid&&uuid.isUUID())return uuid.getUUID();try{if(tag.get("UUIDMost")!=null&&tag.get("UUIDLeast")!=null)return new UUID(number(tag.get("UUIDMost"),"UUID").longValue(),number(tag.get("UUIDLeast"),"UUID").longValue());}catch(IOException ignored){}return null;}
    private static double xpBefore(int n){return n<=16?(double)n*n+6*n:n<=31?2.5*n*n-40.5*n+360:4.5*n*n-162.5*n+2220;}
    private static int xpNext(int n){return n>=30?112+(n-30)*9:n>=15?37+(n-15)*5:7+n*2;}
}
