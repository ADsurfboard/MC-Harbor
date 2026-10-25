package net.morben.shenggan;

import com.google.gson.*;
import java.io.*;
import java.nio.channels.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.regex.*;
import java.util.zip.*;

/** Structural, read-only extraction of FTB quest text and world datapacks. No identifier/command guessing. */
final class NativeTextAssets {
    static final Gson JSON=NativeResourceFiles.JSON;
    static final String INDEX="text-assets.json";
    static final Set<String> QUEST_FIELDS=Set.of("title","subtitle","description","text","hover","quest_desc","quest_subtitle","chapter_subtitle");
    static String str(JsonObject o,String k){return NativeResourceFiles.text(o,k,"");}
    static String sha(byte[] b)throws Exception{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(b));}
    static boolean mode(String kind){return kind.equals("ftbquests")||kind.equals("datapacks");}
    static String decode(byte[] bytes)throws IOException{return StandardCharsets.UTF_8.newDecoder().onMalformedInput(java.nio.charset.CodingErrorAction.REPORT).decode(java.nio.ByteBuffer.wrap(bytes)).toString();}
    static byte[] read(Path p)throws IOException{try(InputStream in=Files.newInputStream(p)){return NativeResourceFiles.bounded(in,4_000_000);}}
    static Path safe(Path base,String relative)throws IOException{
        if(relative.isBlank()||!NativeResourceFiles.safe(relative)||relative.contains(":"))throw new IOException("任务 / 数据包路径无效");
        if(Files.isSymbolicLink(base))throw new IOException("不跟随实例符号链接");Path result=base.resolve(relative).normalize();if(!result.startsWith(base.normalize()))throw new IOException("路径超出实例");
        Path at=base;for(Path part:base.relativize(result)){at=at.resolve(part);if(Files.isSymbolicLink(at))throw new IOException("不跟随任务 / 数据包符号链接");}return result;
    }
    static List<Map<String,Object>> discover(Path run,Path data)throws Exception{
        run=run.toAbsolutePath().normalize();List<Map<String,Object>> out=new ArrayList<>();Set<Path> seen=new HashSet<>();
        for(String rel:List.of("config/ftbquests/quests","config/ftbquests/normal","defaultconfigs/ftbquests/quests"))add(out,seen,run,rel,"ftbquests","FTB Quests · "+rel,data);
        Path saves=run.resolve("saves");if(Files.isDirectory(saves,LinkOption.NOFOLLOW_LINKS))try(var worlds=Files.list(saves)){for(Path world:worlds.sorted().limit(256).toList()){
            if(!Files.isDirectory(world,LinkOption.NOFOLLOW_LINKS)||Files.isSymbolicLink(world))continue;
            String prefix=run.relativize(world).toString();add(out,seen,run,prefix+"/serverconfig/ftbquests/quests","ftbquests","FTB Quests · "+world.getFileName(),data);
            packs(out,seen,run,prefix+"/datapacks","存档「"+world.getFileName()+"」",data);
        }}
        packs(out,seen,run,"datapacks","实例",data);return out;
    }
    static void packs(List<Map<String,Object>> out,Set<Path> seen,Path run,String rel,String name,Path data)throws Exception{
        Path folder=safe(run,rel);if(!Files.isDirectory(folder,LinkOption.NOFOLLOW_LINKS))return;try(var files=Files.list(folder)){for(Path p:files.sorted().limit(512).toList())if(!Files.isSymbolicLink(p)&&(Files.isDirectory(p,LinkOption.NOFOLLOW_LINKS)||p.getFileName().toString().toLowerCase(Locale.ROOT).endsWith(".zip")))add(out,seen,run,run.relativize(p).toString(),"datapacks",name+" · "+p.getFileName(),data);}
    }
    static void add(List<Map<String,Object>> out,Set<Path> seen,Path run,String rel,String kind,String name,Path data)throws Exception{
        Path p=safe(run,rel);if(!Files.exists(p,LinkOption.NOFOLLOW_LINKS)||!seen.add(p))return;out.add(NativeResourceFiles.item(p,kind,name,null,null,data));
    }
    static Map<String,byte[]> container(Path source)throws IOException{
        Map<String,byte[]> files=new TreeMap<>();long total=0;int count=0;if(Files.isRegularFile(source)&&Files.size(source)>64_000_000)throw new IOException("数据包超过 64MB，请分包处理");
        if(Files.isDirectory(source,LinkOption.NOFOLLOW_LINKS)){try(var walk=Files.walk(source,16)){for(Path p:walk.filter(f->Files.isRegularFile(f,LinkOption.NOFOLLOW_LINKS)).sorted().limit(20001).toList()){
            if(++count>20000)throw new IOException("任务 / 数据包文件数量过多");String rel=source.relativize(p).toString();safe(source,rel);if(!candidate(rel))continue;byte[] b=read(p);total+=b.length;if(total>64_000_000)throw new IOException("任务 / 数据包文本超过 64MB，请分包处理");files.put(rel,b);
        }}}
        else try(ZipFile zip=new ZipFile(source.toFile())){if(zip.size()>20000)throw new IOException("数据包文件数量过多");for(ZipEntry entry:Collections.list(zip.entries())){
            if(entry.isDirectory())continue;String rel=entry.getName();if(!NativeResourceFiles.safe(rel)||rel.contains(":"))throw new IOException("数据包包含不安全路径");if(!candidate(rel))continue;
            try(InputStream in=zip.getInputStream(entry)){byte[] b=NativeResourceFiles.bounded(in,4_000_000);total+=b.length;if(total>64_000_000)throw new IOException("任务 / 数据包文本过大");if(files.put(rel,b)!=null)throw new IOException("数据包存在重复文件路径");}
        }}return files;
    }
    static boolean candidate(String rel){String s=rel.toLowerCase(Locale.ROOT);return s.endsWith(".json")||s.endsWith(".json5")||s.endsWith(".snbt")||s.endsWith(".lang")||s.endsWith(".mcfunction")||s.equals("pack.mcmeta");}
    static final class Node {
        int start,end;String value,raw;Map<String,Node> object;List<Node> list;String typed="";
        boolean string(){return value!=null;}
        Node copy(){Node n=new Node();n.start=start;n.end=end;n.value=value;n.raw=raw;n.typed=typed;if(object!=null){n.object=new LinkedHashMap<>();object.forEach((k,v)->n.object.put(k,v.copy()));}if(list!=null)n.list=list.stream().map(Node::copy).collect(java.util.stream.Collectors.toCollection(ArrayList::new));return n;}
    }
    /** JSON/JSON5 plus FTB SNBT's optional commas, comments, typed arrays and triple-quoted strings. */
    static final class Parser {
        final String s;int p,nodes;Parser(String s){this.s=s;}
        void skip()throws IOException{while(p<s.length()){char c=s.charAt(p);if(Character.isWhitespace(c)||c==','||(p==0&&c=='\uFEFF')){p++;continue;}if(c=='#'||s.startsWith("//",p)){while(p<s.length()&&s.charAt(p)!='\n')p++;continue;}if(s.startsWith("/*",p)){int end=s.indexOf("*/",p+2);if(end<0)throw error();p=end+2;continue;}break;}}
        IOException error(){return new IOException("无法解析任务 / 数据包文本（位置 "+p+"），原文件未修改");}
        String quoted()throws IOException{char q=s.charAt(p++);if(p+1<s.length()&&s.charAt(p)==q&&s.charAt(p+1)==q){p+=2;int end=s.indexOf(""+q+q+q,p);if(end<0)throw error();String v=s.substring(p,end);p=end+3;return v;}
            StringBuilder b=new StringBuilder();while(p<s.length()){char c=s.charAt(p++);if(c==q)return b.toString();if(c!='\\'){b.append(c);continue;}if(p>=s.length())throw error();char e=s.charAt(p++);switch(e){case 'n'->b.append('\n');case 'r'->b.append('\r');case 't'->b.append('\t');case 'b'->b.append('\b');case 'f'->b.append('\f');case '\n'->{}case '\r'->{if(p<s.length()&&s.charAt(p)=='\n')p++;}case 'u','x'->{int len=e=='u'?4:2;if(p+len>s.length())throw error();try{b.append((char)Integer.parseInt(s.substring(p,p+len),16));}catch(NumberFormatException ex){throw error();}p+=len;}default->b.append(e);}}throw error();}
        String key()throws IOException{skip();if(p>=s.length())throw error();char c=s.charAt(p);if(c=='"'||c=='\'')return quoted();int start=p;while(p<s.length()&&!Character.isWhitespace(s.charAt(p))&&s.charAt(p)!=':')p++;if(start==p)throw error();return s.substring(start,p);}
        Node value(int depth)throws IOException{skip();if(depth>96||++nodes>200000||p>=s.length())throw error();Node n=new Node();n.start=p;char c=s.charAt(p);
            if(c=='{'){p++;n.object=new LinkedHashMap<>();skip();while(p<s.length()&&s.charAt(p)!='}'){String key=key();skip();if(p>=s.length()||s.charAt(p++)!=':')throw error();if(n.object.put(key,value(depth+1))!=null)throw new IOException("任务 / 数据包存在重复键："+key);skip();}if(p>=s.length())throw error();p++;}
            else if(c=='['){p++;n.list=new ArrayList<>();skip();if(p+1<s.length()&&"BILbil".indexOf(s.charAt(p))>=0&&s.charAt(p+1)==';'){n.typed=s.substring(p,p+2);p+=2;}skip();while(p<s.length()&&s.charAt(p)!=']'){n.list.add(value(depth+1));skip();}if(p>=s.length())throw error();p++;}
            else if(c=='"'||c=='\''){n.value=quoted();}
            else{int start=p;while(p<s.length()&&!Character.isWhitespace(s.charAt(p))&&",]}".indexOf(s.charAt(p))<0)p++;if(start==p)throw error();n.raw=s.substring(start,p);if(!n.raw.matches("(?i)(?:true|false|null|[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:e[+-]?[0-9]+)?[bslfd]?|[+-]?(?:Infinity|NaN)|0x[0-9a-f]+)"))n.value=n.raw;}
            n.end=p;return n;
        }
        Node parse()throws IOException{Node n=value(0);skip();if(p!=s.length())throw error();return n;}
    }
    static String escape(String s){return s.replace("~","~0").replace("/","~1");}
    static Node at(Node root,String pointer){Node n=root;for(String part:pointer.split("/",-1)){if(part.isEmpty())continue;String key=part.replace("~1","/").replace("~0","~");try{n=n.object!=null?n.object.get(key):n.list.get(Integer.parseInt(key));}catch(Exception e){return null;}if(n==null)return null;}return n;}
    static void walk(Node n,String pointer,boolean all,boolean inherited,boolean book,Map<String,Node> out){
        if(n.string()){if((all||inherited)&&!n.value.isBlank()&&!n.value.strip().matches("\\{[^{}]+}"))out.put(pointer,n);return;}
        if(n.object!=null)n.object.forEach((k,v)->walk(v,pointer+"/"+escape(k),all,QUEST_FIELDS.contains(k)||(book&&k.equals("name"))||k.equals("fallback"),book,out));
        if(n.list!=null)for(int i=0;i<n.list.size();i++)walk(n.list.get(i),pointer+"/"+i,all,inherited,book,out);
    }
    static String quote(String value,boolean snbt){
        if(!snbt)return JSON.toJson(value);StringBuilder b=new StringBuilder("\"");for(char c:value.toCharArray())switch(c){case '"'->b.append("\\\"");case '\\'->b.append("\\\\");case '\n'->b.append("\\n");case '\r'->b.append("\\r");case '\t'->b.append("\\t");case '\b'->b.append("\\b");case '\f'->b.append("\\f");default->b.append(c);}return b.append('"').toString();
    }
    static String serialize(Node n,boolean snbt){if(n.object!=null){List<String> a=new ArrayList<>();n.object.forEach((k,v)->a.add(quote(k,snbt)+": "+serialize(v,snbt)));return "{\n"+String.join(",\n",a)+"\n}";}if(n.list!=null)return "["+n.typed+String.join(", ",n.list.stream().map(v->serialize(v,snbt)).toList())+"]";return n.string()?quote(n.value,snbt):n.raw;}

    static Node merge(Node english,Node chinese){if(chinese==null)return english.copy();if(english.list!=null&&chinese.list!=null){Node n=english.copy();for(int i=0;i<chinese.list.size();i++){if(i<n.list.size())n.list.set(i,merge(n.list.get(i),chinese.list.get(i)));else n.list.add(chinese.list.get(i).copy());}return n;}if(english.object!=null&&chinese.object!=null){Node n=english.copy();chinese.object.forEach((k,v)->n.object.put(k,n.object.containsKey(k)?merge(n.object.get(k),v):v.copy()));return n;}return english.object!=null||english.list!=null?english.copy():chinese.copy();}
    static String chinesePath(String rel){return rel.replaceFirst("(?i)(^|/)en_(?:us|gb)(?=/|\\.)","$1zh_cn");}
    static boolean nativeLocale(String rel){return rel.toLowerCase(Locale.ROOT).matches(".*(?:^|/)lang/(?:en_us|en_gb)(?:/.*|\\.(?:snbt|json5|json))");}
    static boolean chinese(String value){return value.codePoints().anyMatch(c->Character.UnicodeScript.of(c)==Character.UnicodeScript.HAN);}
    static Map<String,byte[]> extract(Path source,String kind,Path folder,Path run,List<String> warnings)throws Exception{
        Map<String,byte[]> files=container(source),documents=new TreeMap<>();Map<String,String> en=new TreeMap<>(),zh=new TreeMap<>();JsonArray docs=new JsonArray();JsonObject old=NativeResourceFiles.object(folder.resolve(INDEX)),applied=NativeResourceFiles.object(folder.resolve("text-applied.json"));
        Set<String> locales=new TreeSet<>();Pattern localePattern=Pattern.compile("(?i)^lang/([a-z]{2,3}_[a-z0-9]{2,6})(?:/|\\.)");for(String rel:files.keySet()){Matcher m=localePattern.matcher(rel);if(m.find())locales.add(m.group(1).toLowerCase(Locale.ROOT));}String sourceLocale=locales.contains("en_us")?"en_us":locales.contains("en_gb")?"en_gb":locales.stream().filter(v->!v.equals("zh_cn")).findFirst().orElse("zh_cn");
        Map<String,JsonObject> oldRows=new HashMap<>();if(old.has("documents"))for(JsonElement d:old.getAsJsonArray("documents"))for(JsonElement r:d.getAsJsonObject().getAsJsonArray("rows"))oldRows.put(str(r.getAsJsonObject(),"key"),r.getAsJsonObject());
        for(var entry:files.entrySet()){
            String rel=entry.getKey(),lower=rel.toLowerCase(Locale.ROOT);if(NativeResourceFiles.language(rel)){documents.put(rel,entry.getValue());continue;}
            Matcher localeMatch=localePattern.matcher(rel);boolean locale=kind.equals("ftbquests")&&localeMatch.find()&&localeMatch.group(1).equalsIgnoreCase(sourceLocale);if(kind.equals("ftbquests")&&lower.startsWith("lang/")&&!locale)continue;
            boolean ftb=kind.equals("ftbquests")&&(lower.endsWith(".snbt")||lower.endsWith(".json5")||lower.endsWith(".json"));
            boolean book=kind.equals("datapacks")&&lower.contains("/patchouli_books/");boolean function=kind.equals("datapacks")&&lower.startsWith("data/")&&lower.endsWith(".mcfunction");
            boolean data=kind.equals("datapacks")&&(lower.equals("pack.mcmeta")||lower.startsWith("data/")&&(lower.contains("/advancement/")||lower.contains("/advancements/")||book||lower.contains("/quests/")))&&(lower.endsWith(".json")||lower.endsWith(".json5")||lower.equals("pack.mcmeta"));
            if(!ftb&&!data&&!function)continue;
            try{
                String content=decode(entry.getValue());Map<String,Node> nodes=new LinkedHashMap<>();Node tree=null;
                if(function){int start=0,line=0;for(String s:content.split("\n",-1)){line++;if(Pattern.compile("(?:^|\\srun\\s)(?:tellraw|title)\\s").matcher(s.stripLeading()).find()){
                    Matcher command=Pattern.compile("(?:^|\\srun\\s)(?:tellraw\\s+\\S+\\s+|title\\s+\\S+\\s+(?:title|subtitle|actionbar)\\s+)").matcher(s);if(command.find()){int pos=command.end();Parser parser=new Parser(content);parser.p=start+pos;Node node=parser.value(0);Map<String,Node> found=new LinkedHashMap<>();walk(node,"/line"+line,false,node.string(),false,found);nodes.putAll(found);}
                }start+=s.length()+1;}}
                else{tree=new Parser(content).parse();walk(tree,"",locale,false,book,nodes);}
                if(nodes.isEmpty())continue;
                String target=locale?rel.replaceFirst("(?i)(^|/)"+Pattern.quote(sourceLocale)+"(?=/|\\.)","$1zh_cn"):rel;for(String actual:files.keySet())if(actual.equalsIgnoreCase(target)){target=actual;break;}byte[] previous=files.get(target);Node chineseTree=locale&&previous!=null?new Parser(decode(previous)).parse():null;
                JsonObject doc=new JsonObject();doc.addProperty("source",rel);doc.addProperty("target",target);doc.addProperty("nativeLocale",locale);doc.addProperty("function",function);doc.addProperty("sourceSHA256",sha(entry.getValue()));doc.addProperty("targetSHA256",previous==null?"":sha(previous));JsonArray rows=new JsonArray();
                for(var node:nodes.entrySet()){
                    String key=rel+"#"+node.getKey(),english=node.getValue().value;Node existing=locale?at(chineseTree==null?new Node():chineseTree,node.getKey()):null;String translated=existing!=null&&existing.string()?existing.value:chinese(english)?english:"";
                    JsonObject before=oldRows.get(key);if(!locale&&before!=null&&applied.has(rel)&&applied.get(rel).getAsString().equals(sha(entry.getValue()))){translated=english;english=str(before,"source");}
                    en.put(key,english);if(!translated.isEmpty())zh.put(key,translated);JsonObject row=new JsonObject();row.addProperty("key",key);row.addProperty("pointer",node.getKey());row.addProperty("source",english);if(function){row.addProperty("start",node.getValue().start);row.addProperty("end",node.getValue().end);}rows.add(row);
                }
                doc.add("rows",rows);docs.add(doc);Path original=safe(folder.resolve("text-original"),rel);Files.createDirectories(original.getParent());Files.write(original,entry.getValue());if(locale&&previous!=null){Path p=safe(folder.resolve("text-original"),target);Files.createDirectories(p.getParent());Files.write(p,previous);}
            }catch(IOException|IllegalArgumentException e){warnings.add(source.getFileName()+"/"+rel+"："+e.getMessage());}
        }
        if(!en.isEmpty()){
            String ns="harbor_text_"+NativeResourceFiles.digest(source.toString().getBytes(StandardCharsets.UTF_8)).substring(0,12);documents.put("assets/"+ns+"/lang/en_us.json",JSON.toJson(en).getBytes(StandardCharsets.UTF_8));documents.put("assets/"+ns+"/lang/zh_cn.json",JSON.toJson(zh).getBytes(StandardCharsets.UTF_8));
            JsonObject index=new JsonObject();index.addProperty("runDirectory",run.toAbsolutePath().normalize().toString());index.addProperty("installRelative",run.toAbsolutePath().normalize().relativize(source.toAbsolutePath().normalize()).toString());index.addProperty("archive",!Files.isDirectory(source));index.addProperty("archiveSHA256",Files.isDirectory(source)?"":sha(Files.readAllBytes(source)));index.addProperty("namespace",ns);index.add("documents",docs);Files.createDirectories(folder);Files.writeString(folder.resolve(INDEX),JSON.toJson(index));
        }
        if(en.isEmpty())Files.deleteIfExists(folder.resolve(INDEX));return documents;
    }
    record Patch(Path target,byte[] bytes,String expected,String relative,Path sourceFolder){}
    static List<Patch> patches(Path folder,JsonArray entries,boolean raw)throws Exception{
        if(raw||!Files.isRegularFile(folder.resolve(INDEX)))return List.of();JsonObject index=NativeResourceFiles.object(folder.resolve(INDEX));Map<String,String> values=new HashMap<>();for(JsonElement e:entries){JsonObject row=e.getAsJsonObject();String translated=str(row,"translation");if(str(row,"namespace").equals(str(index,"namespace"))&&!translated.isEmpty()&&NativeLocalization.compatible(str(row,"source"),translated))values.put(str(row,"key"),translated);}
        Path run=Path.of(str(index,"runDirectory")),source=safe(run,str(index,"installRelative"));Map<String,byte[]> changes=new LinkedHashMap<>();Map<String,String> expected=new HashMap<>();
        for(JsonElement d:index.getAsJsonArray("documents")){
            JsonObject doc=d.getAsJsonObject();String rel=str(doc,"source"),target=str(doc,"target");if(!index.get("archive").getAsBoolean()&&!current(safe(source,rel)).equals(str(doc,"sourceSHA256")))throw new IOException("任务 / 数据包原文已变化，请重新读取再导出或应用");boolean nativeLocale=doc.get("nativeLocale").getAsBoolean();String content=Files.readString(safe(folder.resolve("text-original"),rel));List<int[]> spans=new ArrayList<>();List<String> replacements=new ArrayList<>();Node tree=doc.get("function").getAsBoolean()?null:new Parser(content).parse();Node output=tree;
            if(nativeLocale){Path previous=safe(folder.resolve("text-original"),target);output=merge(tree,!str(doc,"targetSHA256").isEmpty()&&Files.isRegularFile(previous)?new Parser(Files.readString(previous)).parse():null);}
            boolean changed=false;
            for(JsonElement e:doc.getAsJsonArray("rows")){JsonObject row=e.getAsJsonObject();String value=values.get(str(row,"key"));if(value==null)continue;String pointer=str(row,"pointer");
                if(nativeLocale){Node n=at(output,pointer);if(n!=null&&n.string()&&!value.equals(n.value)){n.value=value;changed=true;}else if(str(doc,"targetSHA256").isEmpty())changed=true;}
                else{Node n=tree==null?null:at(tree,pointer);int begin=n==null?row.get("start").getAsInt():n.start,end=n==null?row.get("end").getAsInt():n.end;String old=n==null?new Parser(content.substring(begin,end)).parse().value:n.value;if(!value.equals(old)){spans.add(new int[]{begin,end});replacements.add(quote(value,rel.endsWith(".snbt")));changed=true;}}
            }
            if(!changed)continue;byte[] bytes;
            if(nativeLocale)bytes=serialize(output,target.endsWith(".snbt")).getBytes(StandardCharsets.UTF_8);else{StringBuilder s=new StringBuilder(content);List<Integer> order=new ArrayList<>();for(int i=0;i<spans.size();i++)order.add(i);order.sort(Comparator.comparingInt((Integer i)->spans.get(i)[0]).reversed());for(int i:order)s.replace(spans.get(i)[0],spans.get(i)[1],replacements.get(i));bytes=s.toString().getBytes(StandardCharsets.UTF_8);if(tree!=null)new Parser(new String(bytes,StandardCharsets.UTF_8)).parse();}
            if(changes.put(target,bytes)!=null)throw new IOException("任务译文目标冲突："+target);expected.put(target,str(doc,"targetSHA256"));
        }
        List<Patch> result=new ArrayList<>();String install=str(index,"installRelative");
        if(index.get("archive").getAsBoolean()&&!changes.isEmpty()){
            if(!sha(Files.readAllBytes(source)).equals(str(index,"archiveSHA256")))throw new IOException("数据包已发生变化，请重新读取后再导出或应用");ByteArrayOutputStream b=new ByteArrayOutputStream();try(ZipOutputStream z=new ZipOutputStream(b);ZipFile original=new ZipFile(source.toFile())){long total=0;for(ZipEntry e:Collections.list(original.entries())){if(e.isDirectory())continue;String rel=e.getName();if(!NativeResourceFiles.safe(rel))throw new IOException("数据包路径无效");byte[] payload=changes.remove(rel);if(payload==null)try(InputStream in=original.getInputStream(e)){payload=NativeResourceFiles.bounded(in,16_000_000);}total+=payload.length;if(total>64_000_000)throw new IOException("数据包超过安全处理大小");z.putNextEntry(new ZipEntry(rel));z.write(payload);z.closeEntry();}if(!changes.isEmpty())throw new IOException("不能向未知数据包结构添加文件");}result.add(new Patch(source,b.toByteArray(),str(index,"archiveSHA256"),install,folder));
        }else for(var e:changes.entrySet()){Path target=safe(source,e.getKey());result.add(new Patch(target,e.getValue(),expected.get(e.getKey()),install+"/"+e.getKey(),folder));}
        return result;
    }
    static int export(Path folder,JsonArray entries,ZipOutputStream zip,boolean raw,Set<String> written)throws Exception{
        if(!Files.isRegularFile(folder.resolve(INDEX)))return 0;JsonObject index=NativeResourceFiles.object(folder.resolve(INDEX));
        if(raw){try(var paths=Files.walk(folder.resolve("text-original"))){for(Path p:paths.filter(Files::isRegularFile).sorted().toList()){String name="original-text/"+folder.getFileName()+"/"+folder.resolve("text-original").relativize(p);put(zip,name,Files.readAllBytes(p),written);}}return 0;}
        List<Patch> patches=patches(folder,entries,false);for(Patch p:patches)put(zip,"overrides/"+p.relative,p.bytes,written);return patches.size();
    }
    static void put(ZipOutputStream z,String name,byte[] bytes,Set<String> written)throws IOException{if(!NativeResourceFiles.safe(name)||!written.add(name))throw new IOException("汉化包存在重复目标");z.putNextEntry(new ZipEntry(name));z.write(bytes);z.closeEntry();}
    static String current(Path p)throws Exception{return Files.isRegularFile(p,LinkOption.NOFOLLOW_LINKS)?sha(Files.readAllBytes(p)):"";}
    static Map<String,Object> apply(Path run,Path data,List<Patch> all)throws Exception{
        if(all.isEmpty())return Map.of("files",0,"backup","");run=run.toAbsolutePath().normalize();Set<Path> targets=new HashSet<>();for(Patch p:all){if(!targets.add(p.target)||!safe(run,p.relative).equals(p.target)||!current(p.target).equals(p.expected))throw new IOException("文件已变化或目标重复，请重新读取再应用");}
        List<FileChannel> channels=new ArrayList<>();List<FileLock> locks=new ArrayList<>();Map<Path,byte[]> before=new LinkedHashMap<>();Map<Path,Path> stages=new LinkedHashMap<>();List<Path> committed=new ArrayList<>();
        Path backup=data.resolve("backups/localization/"+System.currentTimeMillis()+"-"+UUID.randomUUID()+".zip");
        try{
            Path saves=run.resolve("saves");if(Files.isDirectory(saves))try(var worlds=Files.list(saves)){for(Path world:worlds.limit(256).toList()){Path f=world.resolve("session.lock");if(!Files.isRegularFile(f,LinkOption.NOFOLLOW_LINKS))continue;FileChannel c=FileChannel.open(f,StandardOpenOption.WRITE);channels.add(c);FileLock lock=c.tryLock();if(lock==null)throw new IOException("有存档正在游戏中使用，请关闭游戏后应用汉化");locks.add(lock);}}
            for(Patch p:all){if(!current(p.target).equals(p.expected))throw new IOException("文件已变化，请重新读取");if(Files.exists(p.target))before.put(p.target,Files.readAllBytes(p.target));Files.createDirectories(p.target.getParent());Path temp=Files.createTempFile(p.target.getParent(),".harbor-text-",".tmp");Files.write(temp,p.bytes);stages.put(p.target,temp);}
            Files.createDirectories(backup.getParent());try(ZipOutputStream zip=new ZipOutputStream(Files.newOutputStream(backup,StandardOpenOption.CREATE_NEW))){Set<String> names=new HashSet<>();List<String> created=new ArrayList<>();for(Patch p:all){byte[] original=before.get(p.target);if(original==null)created.add(p.relative);else put(zip,p.relative,original,names);}put(zip,"MC-Harbor-backup.json",JSON.toJson(Map.of("createdFiles",created,"kind","FTB Quests and datapack translations","restore","Restore original entries to the instance and remove only the listed newly-created files.")).getBytes(StandardCharsets.UTF_8),names);}
            try(ZipFile verify=new ZipFile(backup.toFile())){for(ZipEntry e:Collections.list(verify.entries()))try(InputStream in=verify.getInputStream(e)){CRC32 crc=new CRC32();byte[] b=new byte[65536];for(int n;(n=in.read(b))>0;)crc.update(b,0,n);if(crc.getValue()!=e.getCrc())throw new IOException("汉化备份校验失败");}}
            for(Patch p:all){safe(run,p.relative);if(!current(p.target).equals(p.expected))throw new IOException("应用时文件发生变化");Files.move(stages.get(p.target),p.target,StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE);committed.add(p.target);}
            for(Patch p:all){JsonObject applied=NativeResourceFiles.object(p.sourceFolder.resolve("text-applied.json"));JsonObject index=NativeResourceFiles.object(p.sourceFolder.resolve(INDEX));if(!index.get("archive").getAsBoolean())applied.addProperty(Path.of(str(index,"runDirectory")).resolve(str(index,"installRelative")).relativize(p.target).toString(),sha(p.bytes));Files.writeString(p.sourceFolder.resolve("text-applied.json"),JSON.toJson(applied));}
            return Map.of("files",all.size(),"backup",backup.toString());
        }catch(Exception e){Collections.reverse(committed);for(Path p:committed){byte[] b=before.get(p);if(b==null)Files.deleteIfExists(p);else{Path t=Files.createTempFile(p.getParent(),".harbor-text-rollback-",".tmp");Files.write(t,b);Files.move(t,p,StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE);}}throw e;
        }finally{for(Path stage:stages.values())Files.deleteIfExists(stage);for(FileLock lock:locks)try{lock.release();}catch(IOException ignored){}for(FileChannel c:channels)try{c.close();}catch(IOException ignored){}}
    }
}
