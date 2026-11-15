#!/usr/bin/env python3
"""Independent Python ZIP decoder verifies actual Swift pack/backup output."""
from pathlib import Path
import subprocess, tempfile, zipfile, json, base64
root = Path(__file__).resolve().parents[1]
producer = r'''
import Foundation
@main struct Run {
  static func main() throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    let source = Data(#"{"item.example.tool":"Tool %s"}"#.utf8)
    var doc = try LocalizationDocument.read(source, path:"assets/example/lang/en_us.json", kind:.languageJSON)
    doc.rows[0].translation = "工具 %s"
    let project = LocalizationProject(name:"汉化校验", sources:[.init(name:"Example", installPath:"mods/example.jar", kind:"mods", documents:[doc])])
    try LocalizationZIP.write(LocalizationPack.entries(project, sourceOnly:false), to:output.appendingPathComponent("translated.zip"))
    try LocalizationZIP.write(LocalizationPack.entries(project, sourceOnly:true), to:output.appendingPathComponent("source.zip"))
    let instance = output.appendingPathComponent("instance"), file = instance.appendingPathComponent("config/ftbquests/quests/start.snbt")
    try FileManager.default.createDirectory(at:file.deletingLastPathComponent(), withIntermediateDirectories:true)
    let text=Data("{id:'ABC' title:'Start' rewards:[{xp:25}]}".utf8);try text.write(to:file)
    var quest=try LocalizationDocument.read(text,path:"start.snbt",kind:.ftbQuest);quest.rows[0].translation="开始"
    let tasks=LocalizationProject(name:"Tasks",sources:[.init(name:"FTB",installPath:"config/ftbquests/quests",kind:"ftbquests",documents:[quest])])
    let result=try LocalizationApply.apply(tasks,instance:instance,backupHome:output)
    try FileManager.default.copyItem(at:result.backup!,to:output.appendingPathComponent("backup.zip"))
    let locale=instance.appendingPathComponent("config/ftbquests/quests/lang")
    try FileManager.default.createDirectory(at:locale,withIntermediateDirectories:true)
    try Data("{title:'Welcome' next:'Next %s'}".utf8).write(to:locale.appendingPathComponent("en_us.snbt"))
    let chinese=Data("{title:'原译文' extra:'保留'}".utf8);try chinese.write(to:locale.appendingPathComponent("zh_cn.snbt"))
    var localized=LocalizationProject(name:"Native FTB",sources:try LocalizationScanner.loose(instance:instance).sources.filter{$0.kind == "ftbquests"})
    for s in localized.sources.indices { for d in localized.sources[s].documents.indices where localized.sources[s].documents[d].kind == .ftbLocale {
      for r in localized.sources[s].documents[d].rows.indices where localized.sources[s].documents[d].rows[r].key == "/next" {localized.sources[s].documents[d].rows[r].translation="下一步 %s"}
    }}
    let merged=try LocalizationApply.apply(localized,instance:instance,backupHome:output)
    try FileManager.default.copyItem(at:merged.backup!,to:output.appendingPathComponent("locale-backup.zip"))
    let document=try LocalizationDocument.read(Data(contentsOf:locale.appendingPathComponent("zh_cn.snbt")),path:"lang/zh_cn.snbt",kind:.ftbLocale)
    guard document.rows.first(where:{$0.key == "/extra"})?.source == "保留",document.rows.first(where:{$0.key == "/next"})?.source == "下一步 %s" else{throw ResourceError.invalid("native Chinese FTB merge failed")}
    let zipPath="saves/World/datapacks/input.zip",zip=instance.appendingPathComponent(zipPath)
    try FileManager.default.createDirectory(at:zip.deletingLastPathComponent(),withIntermediateDirectories:true)
    try FileManager.default.copyItem(at:output.appendingPathComponent("datapack-input.zip"),to:zip)
    let encoded=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:output.appendingPathComponent("datapack-entries.json")))
    let entries=try encoded.mapValues { value in guard let data=Data(base64Encoded:value) else{throw ResourceError.invalid("fixture decode failed")};return data }
    var zipSource=try LocalizationDatapackZIP.scan(entries:entries,name:"ZIP fixture",installPath:zipPath,revision:LocalizationDatapackZIP.revision(zip))
    for d in zipSource.documents.indices {for r in zipSource.documents[d].rows.indices{zipSource.documents[d].rows[r].translation="译文 "+zipSource.documents[d].rows[r].source}}
    let zipProject=LocalizationProject(name:"ZIP fixture",sources:[zipSource])
    try LocalizationZIP.write(LocalizationPack.entries(zipProject,sourceOnly:false),to:output.appendingPathComponent("datapack-outer-pack.zip"))
    let applied=try LocalizationApply.apply(zipProject,instance:instance,backupHome:output)
    try FileManager.default.copyItem(at:zip,to:output.appendingPathComponent("datapack-output.zip"))
    try FileManager.default.copyItem(at:applied.backup!,to:output.appendingPathComponent("datapack-backup.zip"))
  }
}
'''
with tempfile.TemporaryDirectory(prefix='harbor-localization-zip-') as temporary:
    home = Path(temporary); source = home/'Producer.swift'; source.write_text(producer); binary = home/'produce'
    entries={'pack.mcmeta':json.dumps({'pack':{'pack_format':15,'description':'Adventure'}}).encode(),
             'data/qa/advancements/start.json':json.dumps({'display':{'title':{'text':'Find stone'}},'criteria':{'id':{'trigger':'minecraft:impossible'}}}).encode(),
             'data/qa/structure/原始.nbt':bytes([0,255,128,17,31,99,0])}
    with zipfile.ZipFile(home/'datapack-input.zip','w',compression=zipfile.ZIP_DEFLATED) as archive:
        for name,data in entries.items(): archive.writestr(name,data)
    (home/'datapack-entries.json').write_text(json.dumps({name:base64.b64encode(data).decode() for name,data in entries.items()}))
    production = sorted((root/'HarborCore/Sources/HarborCore').glob('Resource*.swift')) + sorted((root/'HarborCore/Sources/HarborCore').glob('Localization*.swift'))
    subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',*map(str,production),str(source),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(home)],check=True,timeout=45)
    for name in ['translated.zip','source.zip','backup.zip']:
        with zipfile.ZipFile(home/name) as archive:
            assert archive.testzip() is None, name+' CRC mismatch'
            assert len(archive.namelist()) == len(set(archive.namelist()))
            assert not any(n.startswith('/') or '..' in n.split('/') for n in archive.namelist())
            if name == 'translated.zip':
                assert json.loads(archive.read('assets/example/lang/zh_cn.json')) == {'item.example.tool':'工具 %s'}
                assert json.loads(archive.read('pack.mcmeta'))['pack']['description'].startswith('汉化校验')
            elif name == 'source.zip':
                assert json.loads(archive.read('assets/example/lang/zh_cn.json')) == {'item.example.tool':'Tool %s'}
                index=json.loads(archive.read('AI-translation.json'));assert index[0]['translation']=='' and len(index[0]['id'])==64
                assert next(n for n in archive.namelist() if n.startswith('original/')).endswith('en_us.json')
            else:
                assert archive.read('config/ftbquests/quests/start.snbt') == b"{id:'ABC' title:'Start' rewards:[{xp:25}]}"
                assert json.loads(archive.read('MC-Harbor-backup.json'))['createdFiles']==[]
    print('PASS: independent ZIP/CRC/UTF-8 reader validates translated pack, AI source pack and pre-application original backup.')
    with zipfile.ZipFile(home/'locale-backup.zip') as archive:
        assert archive.testzip() is None
        assert archive.read('config/ftbquests/quests/lang/zh_cn.snbt') == "{title:'原译文' extra:'保留'}".encode()
    print('PASS: existing Chinese FTB merge and byte-identical pre-merge ZIP backup verified.')
    with zipfile.ZipFile(home/'datapack-output.zip') as archive:
        assert archive.testzip() is None and set(archive.namelist())==set(entries)
        assert archive.read('data/qa/structure/原始.nbt') == entries['data/qa/structure/原始.nbt']
        assert json.loads(archive.read('data/qa/advancements/start.json'))=={'display':{'title':{'text':'译文 Find stone'}},'criteria':{'id':{'trigger':'minecraft:impossible'}}}
    with zipfile.ZipFile(home/'datapack-backup.zip') as archive:
        assert archive.read('saves/World/datapacks/input.zip') == (home/'datapack-input.zip').read_bytes()
    with zipfile.ZipFile(home/'datapack-outer-pack.zip') as archive:
        assert archive.testzip() is None
        assert archive.read('overrides/saves/World/datapacks/input.zip') == (home/'datapack-output.zip').read_bytes()
    print('PASS: compressed ZIP datapack translation/application/export, unknown binary preservation and byte-identical original ZIP backup verified by independent decoder.')
