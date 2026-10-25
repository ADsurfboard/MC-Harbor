package net.morben.shenggan;

import com.google.gson.*;
import org.jackhuang.hmcl.download.MojangDownloadProvider;
import java.io.*;
import java.nio.channels.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;

/** Isolated dependency graphs run the production resolver and metadata parser, with fixture downloads. */
public final class DependencyChecks {
    private static final Map<String,Boolean> checks=new LinkedHashMap<>();
    private static Path base;private static int serial;
    static void check(String name,boolean value){checks.put(name,value);System.out.println((value?"PASS ":"FAIL ")+name);}
    interface Throwing {void run()throws Exception;}
    static void reject(String name,Throwing action){try{action.run();check(name,false);}catch(Exception e){check(name,true);}}
    static Path jar(String name,String id,String version,String depends)throws Exception{
        Path path=base.resolve("downloads/"+name);Files.createDirectories(path.getParent());
        String metadata="{\"schemaVersion\":1,\"id\":\""+id+"\",\"version\":\""+version+"\""+(depends.isBlank()?"":",\"depends\":"+depends)+"}";
        zip(path,Map.of("fabric.mod.json",metadata.getBytes(StandardCharsets.UTF_8)));return path;
    }
    static void zip(Path path,Map<String,byte[]> contents)throws Exception{try(ZipOutputStream zip=new ZipOutputStream(Files.newOutputStream(path))){for(var e:contents.entrySet()){zip.putNextEntry(new ZipEntry(e.getKey()));zip.write(e.getValue());zip.closeEntry();}}}
    static NativeDependencies.Release release(String source,String project,String id,Path jar,String game,String loader,List<NativeDependencies.Reference> deps)throws Exception{
        return new NativeDependencies.Release(source,project,id,project,List.of(game),List.of(loader),List.of(new NativeDependencies.Artifact(jar.getFileName().toString(),"https://example.invalid/"+jar.getFileName(),Files.size(jar),Map.of("sha1",NativeDependencies.sha(jar,"SHA-1")))),deps);
    }
    static NativeDependencies.Reference ref(String source,String project){return new NativeDependencies.Reference(source,project,null,false);}
    static Path run(String label,Path... jars)throws Exception{Path run=base.resolve("runs/"+label);Files.createDirectories(run.resolve("mods"));for(Path p:jars)Files.copy(p,run.resolve("mods/"+p.getFileName()));return run;}
    static NativeDependencies resolver(Path run){JsonObject request=new JsonObject();request.addProperty("runDirectory",run.toString());request.addProperty("version","1.20.1");request.addProperty("loader","Fabric");return new NativeDependencies(request,base.resolve("data"),new MojangDownloadProvider(),s->{});}
    static final class Catalog implements NativeDependencies.Catalog {
        final Map<String,List<NativeDependencies.Release>> versions=new HashMap<>();final Map<String,Path> jars=new HashMap<>();final Map<String,List<NativeDependencies.Reference>> searches=new HashMap<>();final Map<String,NativeDependencies.Release> roots=new HashMap<>();boolean unavailable=false;Runnable duringDownload;
        void add(NativeDependencies.Release release,Path file){versions.computeIfAbsent(release.key(),s->new ArrayList<>()).add(release);jars.put(release.id(),file);roots.put(file.getFileName().toString(),release);}
        public List<NativeDependencies.Release> installed(List<Path> files)throws Exception{if(unavailable)throw new IOException("offline");List<NativeDependencies.Release> result=new ArrayList<>();for(Path p:files)if(roots.containsKey(p.getFileName().toString()))result.add(roots.get(p.getFileName().toString()));return result;}
        public List<NativeDependencies.Release> versions(NativeDependencies.Reference ref){List<NativeDependencies.Release> all=ref.project()==null?versions.values().stream().flatMap(List::stream).toList():versions.getOrDefault(ref.source()+":"+ref.project(),List.of());return all.stream().filter(v->ref.version()==null||v.id().equals(ref.version())).toList();}
        public List<NativeDependencies.Reference> search(String id){return searches.getOrDefault(id,List.of());}
        public Path download(NativeDependencies.Release r,NativeDependencies.Artifact f,Path stage)throws Exception{if(duringDownload!=null)duringDownload.run();Path target=stage.resolve("candidate-"+(serial++)+".jar");Files.copy(jars.get(r.id()),target);return target;}
    }
    public static void main(String[] args)throws Exception{
        base=Path.of(args[0]).toAbsolutePath();Files.createDirectories(base.resolve("downloads"));
        Path a=jar("a.jar","a","1.0.0","{\"b\":\">=1.0.0 <2.0.0\",\"minecraft\":\"1.20.1\"}");
        Path b=jar("b.jar","b","1.2.0","{\"c\":\"^1.0\"}");Path c=jar("c.jar","c","1.0.0","");Path bad=jar("wrong-project.jar","impostor","1.0.0","");Path wrong=jar("b-old.jar","b","0.9.0","");
        var ar=release("modrinth","A","a1",a,"1.20.1","fabric",List.of(ref("modrinth","B")));
        var br=release("modrinth","B","b1",b,"1.20.1","fabric",List.of(ref("curseforge","cf-C")));
        var cr=release("curseforge","cf-C","c1",c,"1.20.1","fabric",List.of());
        Catalog catalog=new Catalog();catalog.add(ar,a);catalog.add(br,b);catalog.add(cr,c);
        Path run=run("recursive",a);String original=NativeDependencies.sha(run.resolve("mods/a.jar"),"SHA-256");
        Map<String,Object> result=resolver(run).complete(catalog);
        check("recursive-MR-and-CF-required-dependencies",((List<?>)result.get("installed")).size()==2&&Files.exists(run.resolve("mods/b.jar"))&&Files.exists(run.resolve("mods/c.jar")));
        check("original-jars-never-replaced",NativeDependencies.sha(run.resolve("mods/a.jar"),"SHA-256").equals(original));
        check("repeat-completion-is-idempotent",((List<?>)resolver(run).complete(catalog).get("installed")).isEmpty());
        var pinnedRoot=new NativeDependencies.Release(ar.source(),ar.project(),ar.id(),ar.name(),ar.games(),ar.loaders(),ar.files(),List.of(new NativeDependencies.Reference("modrinth",null,"new-version",false)));
        Catalog pinned=new Catalog();pinned.add(pinnedRoot,a);pinned.add(br,b);pinned.add(cr,c);pinned.add(new NativeDependencies.Release(br.source(),br.project(),"new-version",br.name(),br.games(),br.loaders(),br.files(),br.dependencies()),b);
        // Keep the installed B descriptor on its actual old version while publishing a distinct pin.
        pinned.roots.put("b.jar",br);Path pinRun=run("pinned",a,b,c);reject("version-only-pinned-conflict-does-not-overwrite",()->resolver(pinRun).complete(pinned));
        check("installed-graph-has-no-missing",NativeModMetadata.scan(run.resolve("mods"),"Fabric").missing().isEmpty());
        Catalog late=new Catalog();var lateRoot=new NativeDependencies.Release(ar.source(),ar.project(),ar.id(),ar.name(),ar.games(),ar.loaders(),ar.files(),List.of(new NativeDependencies.Reference("modrinth","B",null,true),ref("curseforge","cf-C")));var lateC=new NativeDependencies.Release(cr.source(),cr.project(),cr.id(),cr.name(),cr.games(),cr.loaders(),cr.files(),List.of(ref("modrinth","B")));late.add(lateRoot,a);late.add(br,b);late.add(lateC,c);Path lateRun=run("late-incompatible",a);boolean lateRejected=false;try{resolver(lateRun).complete(late);}catch(IOException expected){lateRejected=true;}check("late-platform-incompatibility-rejected-before-commit",lateRejected&&Files.list(lateRun.resolve("mods")).count()==1);
        check("fabric-version-AND",NativeModMetadata.matches("1.2.3",List.of(">=1.0 <2.0"))&&!NativeModMetadata.matches("2.0.0",List.of(">=1.0 <2.0")));
        check("fabric-caret-zero",NativeModMetadata.matches("0.2.5",List.of("^0.2.0"))&&!NativeModMetadata.matches("0.3.0",List.of("^0.2.0")));
        check("fabric-tilde",NativeModMetadata.matches("1.2.9",List.of("~1.2.0"))&&!NativeModMetadata.matches("1.3.0",List.of("~1.2.0")));
        check("fabric-wildcard",NativeModMetadata.matches("1.20.1",List.of("1.20.x"))&&!NativeModMetadata.matches("1.21.0",List.of("1.20.x")));
        check("version-OR-list",NativeModMetadata.matches("2.0.1",List.of("^1.0","^2.0")));
        check("Maven-inclusive-exclusive",NativeModMetadata.matches("1.0",List.of("[1.0,2.0)"))&&!NativeModMetadata.matches("2.0",List.of("[1.0,2.0)")));
        check("Maven-open-ended-and-union",NativeModMetadata.matches("3.0",List.of("(,1.0],[2.0,)"))&&!NativeModMetadata.matches("1.5",List.of("(,1.0],[2.0,)")));
        Catalog search=new Catalog();search.searches.put("b",List.of(ref("modrinth","Impostor"),ref("modrinth","B")));search.searches.put("c",List.of(ref("curseforge","cf-C")));
        search.add(release("modrinth","Impostor","wrong",bad,"1.20.1","fabric",List.of()),bad);
        search.add(release("modrinth","B","old",wrong,"1.20.1","fabric",List.of()),wrong);search.add(br,b);search.add(cr,c);
        Path fallback=run("fallback",a);resolver(fallback).complete(search);
        check("search-candidates-verified-by-actual-mod-ID",!Files.exists(fallback.resolve("mods/wrong-project.jar"))&&Files.exists(fallback.resolve("mods/b.jar")));
        check("wrong-dependency-version-skipped",!Files.exists(fallback.resolve("mods/b-old.jar")));
        Catalog wrongLoader=new Catalog();wrongLoader.add(ar,a);wrongLoader.add(release("modrinth","B","wrongloader",b,"1.20.1","forge",List.of()),b);Path lr=run("wrong-loader",a);reject("wrong-loader-never-installed",()->resolver(lr).complete(wrongLoader));check("resolution-failure-leaves-no-partial-install",Files.list(lr.resolve("mods")).count()==1);
        Path disabled=run("disabled",a);Files.copy(b,disabled.resolve("mods/b.jar.disabled"));reject("disabled-dependency-not-silently-enabled",()->resolver(disabled).complete(catalog));
        Path conflict=run("conflict",a,wrong);reject("existing-incompatible-version-not-upgraded",()->resolver(conflict).complete(catalog));check("conflicting-original-preserved",Files.exists(conflict.resolve("mods/b-old.jar"))&&!Files.exists(conflict.resolve("mods/b.jar")));
        Catalog broken=new Catalog();broken.add(ar,a);var brokenB=new NativeDependencies.Release(br.source(),br.project(),"badsha",br.name(),br.games(),br.loaders(),List.of(new NativeDependencies.Artifact("b.jar","https://example.invalid/b.jar",Files.size(b),Map.of("sha1","0000000000000000000000000000000000000000"))),br.dependencies());broken.add(brokenB,b);Path corrupt=run("hash",a);reject("download-hash-failure-rejected",()->resolver(corrupt).complete(broken));check("hash-failure-does-not-install",Files.list(corrupt.resolve("mods")).count()==1);
        Path blocked=run("lock",a);Files.createDirectories(blocked.resolve(".harbor"));try(FileChannel channel=FileChannel.open(blocked.resolve(".harbor/dependency-completion.lock"),StandardOpenOption.CREATE,StandardOpenOption.WRITE);FileLock lock=channel.lock()){reject("concurrent-completion-lock",()->resolver(blocked).complete(catalog));}
        Path race=run("race",a);Catalog changing=new Catalog();changing.add(ar,a);changing.add(br,b);changing.add(cr,c);changing.duringDownload=()->{try{Files.writeString(race.resolve("mods/external.txt"),"other editor");}catch(IOException e){throw new UncheckedIOException(e);}};reject("concurrent-file-change-detected",()->resolver(race).complete(changing));check("external-change-and-original-retained",Files.exists(race.resolve("mods/external.txt"))&&!Files.exists(race.resolve("mods/b.jar")));
        Path child=jar("embedded.jar","b","1.2.0","");Path parent=base.resolve("downloads/embedded-parent.jar");
        zip(parent,Map.of("fabric.mod.json","{\"id\":\"parent\",\"version\":\"1\",\"depends\":{\"b\":\">=1\"},\"provides\":[\"alias\"],\"jars\":[{\"file\":\"META-INF/jars/b.jar\"}]}".getBytes(StandardCharsets.UTF_8),"META-INF/jars/b.jar",Files.readAllBytes(child)));
        var embedded=NativeModMetadata.archive(parent,"Fabric");check("embedded-and-provides-count-as-installed",embedded.missing().isEmpty()&&embedded.mods.stream().anyMatch(m->m.id().equals("alias")));
        Path optional=base.resolve("downloads/optional.jar");zip(optional,Map.of("fabric.mod.json","{\"id\":\"optional\",\"version\":\"1\",\"suggests\":{\"nothing\":\"*\"},\"recommends\":{\"unneeded\":\"*\"}}".getBytes(StandardCharsets.UTF_8)));check("optional-dependencies-not-installed",NativeModMetadata.archive(optional,"Fabric").missing().isEmpty());
        Path forge=base.resolve("downloads/forge.jar");String toml="modLoader=\"javafml\"\nloaderVersion=\"[47,)\"\n[[mods]]\nmodId=\"forgeqa\"\nversion=\"${file.jarVersion}\"\n[[dependencies.forgeqa]]\nmodId=\"required\"\nmandatory=true\nversionRange=\"[1.0,2.0)\"\nside=\"BOTH\"\n[[dependencies.forgeqa]]\nmodId=\"serveronly\"\nmandatory=true\nside=\"SERVER\"\n[[dependencies.forgeqa]]\nmodId=\"optional\"\nmandatory=false\n";
        zip(forge,Map.of("META-INF/mods.toml",toml.getBytes(StandardCharsets.UTF_8),"META-INF/MANIFEST.MF","Manifest-Version: 1.0\nImplementation-Version: 1.2.3\n\n".getBytes(StandardCharsets.UTF_8)));var fg=NativeModMetadata.archive(forge,"Forge");check("Forge-mandatory-client-side-only",fg.missing().size()==1&&fg.missing().get(0).id().equals("required"));check("manifest-version-placeholder-resolved",fg.mods.get(0).version().equals("1.2.3"));
        Path neo=base.resolve("downloads/neo.jar");zip(neo,Map.of("META-INF/neoforge.mods.toml",toml.replace("mandatory=true","type=\"required\"").replace("mandatory=false","type=\"optional\"").getBytes(StandardCharsets.UTF_8)));check("NeoForge-required-dependency-format",NativeModMetadata.archive(neo,"NeoForge").missing().size()==1);
        Path quilt=base.resolve("downloads/quilt.jar");zip(quilt,Map.of("quilt.mod.json","{\"quilt_loader\":{\"id\":\"quiltqa\",\"version\":\"1\",\"depends\":[{\"id\":\"needed\",\"versions\":\">=1\"},{\"id\":\"skip\",\"optional\":true}]}}".getBytes(StandardCharsets.UTF_8)));check("Quilt-required-versus-optional",NativeModMetadata.archive(quilt,"Quilt").missing().size()==1);
        Path empty=run("empty");Catalog offline=new Catalog();offline.unavailable=true;check("vanilla-with-no-mods-needs-no-network",((List<?>)resolver(empty).complete(offline).get("installed")).isEmpty());
        Map<String,Object> report=Map.of("checks",checks,"passed",checks.values().stream().filter(v->v).count(),"failed",checks.values().stream().filter(v->!v).count(),"realPlayerInstancesModified",false);
        Path output=base.getParent().resolve("dependency-checks-report.json");Files.writeString(output,NativeResourceFiles.JSON.toJson(report));System.out.println(NativeResourceFiles.JSON.toJson(report));if(checks.containsValue(false))System.exit(1);
    }
}
