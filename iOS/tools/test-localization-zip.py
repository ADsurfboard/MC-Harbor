#!/usr/bin/env python3
"""Independent Python ZIP decoder verifies actual Swift pack/backup output."""
from pathlib import Path
import subprocess, tempfile, zipfile, json
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
  }
}
'''
with tempfile.TemporaryDirectory(prefix='harbor-localization-zip-') as temporary:
    home = Path(temporary); source = home/'Producer.swift'; source.write_text(producer); binary = home/'produce'
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
