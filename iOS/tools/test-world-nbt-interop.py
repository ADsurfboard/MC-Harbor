#!/usr/bin/env python3
"""Java DataOutput -> production Swift edits -> HMCL's actual NBT codec.

No player file, app setting, credential or live world is read. All three
compression variants and original root/opaque payload bytes are verified.
"""
from pathlib import Path
import subprocess, tempfile, zipfile
root=Path(__file__).resolve().parents[2]
java=r'''
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;
import org.glavo.nbt.io.NBTCodec;
import org.glavo.nbt.tag.*;
public class NBTInterop {
  static void tag(DataOutputStream out,int type,String name)throws Exception{out.writeByte(type);out.writeUTF(name);}
  static byte[] original()throws Exception{
    ByteArrayOutputStream buffer=new ByteArrayOutputStream();DataOutputStream out=new DataOutputStream(buffer);
    tag(out,10,"FixtureRoot");tag(out,10,"Data");
    tag(out,3,"GameType");out.writeInt(0);tag(out,8,"LevelName");out.writeUTF("原世界\0🌍");
    tag(out,4,"DayTime");out.writeLong(48000);tag(out,10,"Player");
    tag(out,5,"Health");out.writeFloat(20);tag(out,3,"foodLevel");out.writeInt(20);
    tag(out,11,"UUID");out.writeInt(4);for(int v:new int[]{0x00010203,0x04050607,0x08090a0b,0x0c0d0e0f})out.writeInt(v);out.writeByte(0);
    tag(out,10,"ModData");tag(out,1,"Byte");out.writeByte(-128);tag(out,2,"Short");out.writeShort(-32768);
    tag(out,4,"Long");out.writeLong(-1234567890123456789L);tag(out,5,"NaNBits");out.writeInt(0x7fc00042);
    tag(out,6,"Double");out.writeLong(0x8000000000000000L);tag(out,7,"Bytes");out.writeInt(5);out.write(new byte[]{0,-1,-128,17,31});
    tag(out,8,"String");out.writeUTF("keep\0😀\uD800");
    tag(out,9,"List");out.writeByte(10);out.writeInt(2);for(int i=0;i<2;i++){tag(out,8,"id");out.writeUTF("mod:unchanged_"+i);out.writeByte(0);}
    tag(out,11,"Ints");out.writeInt(2);out.writeInt(Integer.MIN_VALUE);out.writeInt(Integer.MAX_VALUE);
    tag(out,12,"Longs");out.writeInt(2);out.writeLong(Long.MIN_VALUE);out.writeLong(Long.MAX_VALUE);
    out.writeByte(0);out.writeByte(0);tag(out,8,"Other");out.writeUTF("Leave this root field intact");out.writeByte(0);out.close();return buffer.toByteArray();
  }
  static byte[] unpack(byte[] bytes,String format)throws Exception{
    if(format.equals("raw"))return bytes;
    try(InputStream in=format.equals("gzip")?new GZIPInputStream(new ByteArrayInputStream(bytes)):new InflaterInputStream(new ByteArrayInputStream(bytes))){return in.readAllBytes();}
  }
  public static void main(String[] args)throws Exception{
    Path folder=Path.of(args[1]);byte[] raw=original();
    if(args[0].equals("generate")){
      Files.write(folder.resolve("raw.input"),raw);
      for(String format:new String[]{"gzip","zlib"}){
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();try(OutputStream out=format.equals("gzip")?new GZIPOutputStream(bytes):new DeflaterOutputStream(bytes)){out.write(raw);}Files.write(folder.resolve(format+".input"),bytes.toByteArray());
      }
    }else{
      for(String format:new String[]{"raw","gzip","zlib"}){
        CompoundTag expected=NBTCodec.of().readTag(raw,CompoundTag.class),data=(CompoundTag)expected.get("Data");
        data.setInt("GameType",1);data.setString("LevelName","新世界\0😀");((CompoundTag)data.get("Player")).setFloat("Health",13.5f);
        CompoundTag actual=NBTCodec.of().readTag(unpack(Files.readAllBytes(folder.resolve(format+".output")),format),CompoundTag.class);
        if(!expected.contentEquals(actual))throw new AssertionError("HMCL NBT codec disagrees with Swift "+format+" output");
      }
      System.out.println("PASS: HMCL NBT codec validates Swift edits, Java modified UTF-8 and all unrelated tags in raw, gzip and zlib documents.");
    }
  }
}
'''
swift=r'''
import Foundation
@main struct Run {
  static func main() async throws {
    let folder=URL(fileURLWithPath:CommandLine.arguments[1])
    for format in ["raw","gzip","zlib"] {
      let original=try Data(contentsOf:folder.appendingPathComponent(format+".input")),doc=try WorldNBTDocument(original)
      guard let mode=try doc.root.at(["Data","GameType"]),let name=try doc.root.at(["Data","LevelName"]),let health=try doc.root.at(["Data","Player","Health"]),let opaque=try doc.root.at(["Data","ModData"]),let uuid=try doc.root.at(["Data","Player","UUID"]) else{throw ResourceError.invalid("fixture fields missing")}
      guard try doc.integer(mode)==0,try doc.string(name)=="原世界\u{0}🌍",try doc.number(health)==20,try doc.uuid(uuid)?.uuidString=="00010203-0405-0607-0809-0A0B0C0D0E0F" else{throw ResourceError.invalid("Java fixture decode failed")}
      let home=folder.appendingPathComponent(format+"-store"),instance=home.appendingPathComponent("instance"),world=instance.appendingPathComponent("saves/World")
      try FileManager.default.createDirectory(at:world,withIntermediateDirectories:true)
      let level=world.appendingPathComponent("level.dat");try original.write(to:level,options:.withoutOverwriting)
      let store=WorldEditorStore(instance:instance,home:home),before=try await store.read(folder:"World")
      let saved=try await store.save(folder:"World",player:before.player,revision:before.revision,changes:["gameMode":.number(1),"name":.text("新世界\u{0}😀"),"health":.number(13.5)])
      guard let backup=saved.backup,saved.values["health"] == .number(13.5) else{throw ResourceError.invalid("transaction or backup missing")}
      try FileManager.default.copyItem(at:backup,to:folder.appendingPathComponent(format+".backup.zip"))
      let output=try Data(contentsOf:level),after=try WorldNBTDocument(output)
      guard let preserved=try after.root.at(["Data","ModData"]),Data(doc.bytes[opaque.payload])==Data(after.bytes[preserved.payload]),doc.bytes.prefix(doc.root.payload.lowerBound)==after.bytes.prefix(after.root.payload.lowerBound) else{throw ResourceError.invalid("untouched payload or root name changed")}
      try output.write(to:folder.appendingPathComponent(format+".output"),options:.withoutOverwriting)
      guard try Data(contentsOf:folder.appendingPathComponent(format+".input"))==original else{throw ResourceError.invalid("source changed")}
    }
  }
}
'''
with tempfile.TemporaryDirectory(prefix='harbor-world-nbt-interop-') as temporary:
    folder=Path(temporary);(folder/'NBTInterop.java').write_text(java);(folder/'Checks.swift').write_text(swift)
    jar=root/'vendor/HMCLCore.jar'
    subprocess.run(['javac','-classpath',str(jar),str(folder/'NBTInterop.java')],check=True)
    command=['java','-classpath',str(folder)+':'+str(jar),'NBTInterop']
    subprocess.run([*command,'generate',str(folder)],check=True,timeout=30)
    production=[]
    for prefix in ['Resource','Localization','World']:
        production+=sorted((root/'iOS/HarborCore/Sources/HarborCore').glob(prefix+'*.swift'))
    subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',*map(str,production),str(folder/'Checks.swift'),'-o',str(folder/'check')],check=True)
    subprocess.run([str(folder/'check'),str(folder)],check=True,timeout=45)
    subprocess.run([*command,'verify',str(folder)],check=True,timeout=30)
    for format in ['raw','gzip','zlib']:
        with zipfile.ZipFile(folder/(format+'.backup.zip')) as archive:
            assert archive.testzip() is None
            assert archive.read('level.dat') == (folder/(format+'.input')).read_bytes()
            assert set(archive.namelist()) == {'level.dat','MC-Harbor-world-backup.json'}
    print('PASS: actual locked WorldEditorStore transactions and independent ZIP/CRC backup-original verification for all three compression formats.')
