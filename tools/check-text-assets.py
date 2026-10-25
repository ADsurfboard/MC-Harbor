"""End-to-end production protocol checks. Only generated FTB / datapack fixtures are modified."""
from pathlib import Path
import json,hashlib,os,subprocess,zipfile,fcntl,shutil,stat
r=Path(__file__).resolve().parent.parent
runnerLock=(r/'evidence/text-assets-run.lock').open('w');fcntl.flock(runnerLock,fcntl.LOCK_EX)
fixture=r/'evidence/text-assets-fixture'
if fixture.exists():shutil.rmtree(fixture) # Only this generated fixture.
run=fixture/'game/versions/TextQA';run.mkdir(parents=True,exist_ok=True);data=fixture/'private';data.mkdir(exist_ok=True)
java='/Library/Java/JavaVirtualMachines/liberica-jdk-21.jdk/Contents/Home/bin/java'
cp=os.pathsep.join(map(str,[r/'build/Backend.jar',Path('/Applications/稳定版我的世界启动器.jar'),*Path('/Applications/.hmcl/dependencies/macos-arm64/openjfx').glob('*21.0.8*.jar')]))
base=dict(root=str(fixture/'game'),runDirectory=str(run),id='TextQA',version='1.20.1',loader='Forge',name='Text QA')
version=json.loads(Path('/Applications/.minecraft/versions/1.20.1/1.20.1.json').read_text());version['id']='TextQA';(run/'TextQA.json').write_text(json.dumps(version))
checks={}
def check(name,value):checks[name]=bool(value);print(('PASS ' if value else 'FAIL ')+name,flush=True)
def call(action,**kw):
 p=subprocess.run([java,'-Xmx384m','-Dshenggan.headless=true','-Djava.awt.headless=true','-Dhmcl.dir='+str(data),'-cp',cp,'net.morben.shenggan.NativeBridge'],input=json.dumps(dict(base,command=action,**kw)),text=True,capture_output=True,timeout=35)
 events=[json.loads(s) for s in p.stdout.splitlines() if s.startswith('{')];errors=[s['message'] for s in events if s.get('event')=='error']
 if errors or p.returncode:raise RuntimeError(errors[0] if errors else p.stderr[-900:])
 return next(e['data'] for e in events if e.get('event')=='result')
def reject(name,action,**kw):
 try:call(action,**kw);check(name,False)
 except RuntimeError:check(name,True)
def write(rel,text):
 p=run/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text);return p
legacy='''{\n // preserve this comment\n id: "CHAPTER_ABC"\n title: "&aGetting Started"\n subtitle: "Hello %s"\n description: ["Collect {item:minecraft:oak_log}", "Line \\"quotes\\"."]\n quests: [{id: "Q_0123", title: "First Steps", tasks: [{id: "T_1", title: "Collect logs", type: "item", item: "minecraft:oak_log", count: 5L}], rewards: [{id: "R_1", title: "Reward", type: "command", command: "say unchanged", auto: true}]}]\n images: [{hover: ["Open guide"], click: "https://example.org/guide"}]\n}'''
# Use valid escaped quotes in the SNBT string.
legacy=legacy.replace('\\\\"','\\"')
quest=write('config/ftbquests/quests/chapters/start.snbt',legacy)
oldlang=write('config/ftbquests/quests/lang/en_us.snbt','{ "title.AAA": "Modern title", "quest_desc.AAA": ["Modern line 1", "Modern line 2"] }')
zh=write('config/ftbquests/quests/lang/zh_cn.snbt','{ "title.AAA": "已有标题", "quest_desc.AAA": ["已有第一行"], "title.EXTRA": "额外中文保留" }')
write('config/ftbquests/quests/lang/en_gb.snbt',json.dumps({'title.AAA':'British duplicate should not conflict'}))
modern=write('config/ftbquests/quests/lang/en_us/chapters/start.json5',"{ // json5\n 'title.BBB': 'Newest title', 'quest_desc.BBB': ['Newest line'], }")
world=run/'saves/Demo';world.mkdir(parents=True,exist_ok=True);(world/'session.lock').write_bytes(b'lock')
pack=world/'datapacks/story.zip';pack.parent.mkdir(exist_ok=True)
adv={'display':{'title':{'text':'A New Beginning','color':'gold'},'description':'Find a stone','icon':{'item':'minecraft:stone'}},'criteria':{'keep_me':{'trigger':'minecraft:inventory_changed','conditions':{'items':[{'items':['minecraft:stone']}]}}},'rewards':{'function':'story:reward'}}
function='execute as @a[tag=harbor] run tellraw @s [{"text":"Welcome "},{"translate":"story.key","with":[{"text":"traveler"}]}]\ntitle @a title "Chapter One"\nsay DO NOT TRANSLATE\nexecute as @a run give @s minecraft:diamond 3\n'
originals={'pack.mcmeta':json.dumps({'pack':{'pack_format':15,'description':'Story Pack'}}).encode(),'data/story/advancements/start.json':json.dumps(adv).encode(),'data/story/functions/welcome.mcfunction':function.encode(),'data/story/loot_tables/rewards.json':b'{"type":"minecraft:chest","pools":[]}', 'data/story/patchouli_books/guide/en_us/entries/start.json':b'{"name":"Guide entry","icon":"minecraft:book","pages":[{"type":"patchouli:text","text":"Read this page"}]}' }
with zipfile.ZipFile(pack,'w') as z:
 for k,v in originals.items():z.writestr(k,v)
archiveBefore=pack.read_bytes()
folder=write('saves/Demo/datapacks/folder/data/story/advancement/another.json',json.dumps({'display':{'title':'Folder title','description':{'text':'Folder description'}}}))
kjs=write('kubejs/assets/custom/lang/en_us.json','{"kjs.title":"KJS original"}')
project=call('langScan');path=project['project'];sources=project['sources'];ftb=next(s for s in sources if s['kind']=='ftbquests');zipped=next(s for s in sources if s['path']==str(pack));loose=next(s for s in sources if s['path']==str(folder.parents[3]));
check('FTB-detected-as-native-resource',ftb['entries']>=12)
check('world-ZIP-and-folder-datapacks',len([s for s in sources if s['kind']=='datapacks'])==2)
check('KubeJS-still-in-workspace',any(s['name']=='kubejs' for s in sources))
check('no-parse-warnings',not project['warnings'])
def rows(source):return call('langRead',project=path,resource=source['id'])['entries']
fr=rows(ftb);zr=rows(zipped);lr=rows(loose)
check('chapter-quest-task-reward-and-hover',all(any(e['source']==v for e in fr) for v in ['&aGetting Started','First Steps','Collect logs','Reward','Open guide']))
check('one-source-locale-prevents-duplicate-targets',not any(e['source']=='British duplicate should not conflict' for e in fr))
check('SNBT-and-new-JSON5-native-language',any(e['source']=='Modern title' and e['translation']=='已有标题' for e in fr) and any(e['source']=='Newest title' for e in fr))
check('no-IDs-conditions-commands-extracted',not any(e['source'] in ['Q_0123','minecraft:oak_log','say unchanged','https://example.org/guide'] for e in fr))
check('datapack-display-and-function-components',all(any(e['source']==v for e in zr) for v in ['A New Beginning','Find a stone','Welcome ','traveler','Chapter One','Guide entry','Read this page']))
check('command-and-translation-key-never-translated',not any(e['source'] in ['story.key','story:reward','minecraft:stone','DO NOT TRANSLATE'] for e in zr))
lookup=lambda source,text:next(e for e in rows(source) if e['source']==text)
reject('FTB-format-code-protected','langSave',project=path,resource=ftb['id'],entry=lookup(ftb,'&aGetting Started')['id'],translation='开始')
reject('FTB-item-link-protected','langSave',project=path,resource=ftb['id'],entry=lookup(ftb,'Collect {item:minecraft:oak_log}')['id'],translation='收集木头')
changes=[]
translations={'&aGetting Started':'&a开始冒险','Hello %s':'你好 %s','Collect {item:minecraft:oak_log}':'收集 {item:minecraft:oak_log}','First Steps':'第一步','Collect logs':'收集原木','Reward':'奖励','Open guide':'打开指南','Modern line 2':'现代第二行','Newest title':'新版本标题','Newest line':'新版本说明','A New Beginning':'新的开始','Find a stone':'找到石头','Welcome ':'欢迎 ','traveler':'旅行者','Chapter One':'第一章','Guide entry':'指南条目','Read this page':'阅读这一页','Folder title':'文件夹标题','Folder description':'文件夹说明'}
translations['Line "quotes".']='中文行\n第二行\u2028分隔'
for src in [ftb,zipped,loose]:
 for row in rows(src):
  if row['source'] in translations:changes.append(dict(resource=src['id'],entry=row['id'],translation=translations[row['source']]))
result=call('langSave',project=path,changes=changes);check('all-kinds-use-same-edit-save',result['saved']==len(changes))
selected=[ftb['id'],zipped['id'],loose['id']]
def output(name):
 p=fixture/name
 if p.exists():p.unlink()
 return str(p)
raw=call('langExport',project=path,selected=selected,packName='任务原文 AI 包',packFormat=15,mode='source',output=output('raw.zip'))
with zipfile.ZipFile(raw['path']) as z:
 check('AI-original-SNBT-and-datapack-files',any(n.endswith('/chapters/start.snbt') and n.startswith('original-text/') for n in z.namelist()) and any(n.endswith('/welcome.mcfunction') for n in z.namelist()))
 check('AI-translation-template-and-catalog','AI-translation.json' in z.namelist() and any(n.startswith('assets/harbor_text_') for n in z.namelist()))
 check('raw-export-never-applies-translations',quest.read_text()==legacy and pack.read_bytes()==archiveBefore)
incoming=fixture/'ai-incoming.zip'
with zipfile.ZipFile(raw['path']) as src,zipfile.ZipFile(incoming,'w') as dst:
 for n in src.namelist():
  if n.startswith('assets/harbor_text_') and n.endswith('/zh_cn.json'):
   values=json.loads(src.read(n));values={k:translations[v] for k,v in values.items() if v in translations};dst.writestr(n,json.dumps(values,ensure_ascii=False))
imported=call('langImport',project=path,selected=selected,file=str(incoming));check('FTB-and-datapack-AI-import-by-mapping',imported['imported']>=len(changes)-1 and imported['rejected']==0)
exported=call('langExport',project=path,selected=selected,packName='完整汉化包',packFormat=15,output=output('translated.zip'))
with zipfile.ZipFile(exported['path']) as z:
 check('bundle-has-FTB-and-world-overrides',all(n in z.namelist() for n in ['overrides/config/ftbquests/quests/chapters/start.snbt','overrides/config/ftbquests/quests/lang/zh_cn.snbt','overrides/config/ftbquests/quests/lang/zh_cn/chapters/start.json5','overrides/saves/Demo/datapacks/story.zip']))
 check('explicit-pack-vs-quest-instructions','overrides' in z.read('README.txt').decode())
 before={p:p.read_bytes() for p in [quest,oldlang,zh,modern,pack,folder,kjs]}
 with (world/'session.lock').open('r+b') as lock:
  fcntl.lockf(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);reject('active-world-stops-all-application','langApply',project=path,selected=selected)
 check('active-rejection-leaves-all-originals',all(p.read_bytes()==b for p,b in before.items()))
 try:
  os.chflags(zh,stat.UF_IMMUTABLE)
  reject('failed-second-write-triggers-rollback','langApply',project=path,selected=selected)
 finally:os.chflags(zh,0)
 check('rollback-restores-all-original-bytes',all(p.read_bytes()==b for p,b in before.items()))
 applied=call('langApply',project=path,selected=selected);check('one-click-application-backed-up',applied['files']>=5 and Path(applied['backup']).is_file())
check('FTB-inline-text-replaced',all(t in quest.read_text() for t in ['开始冒险','第一步','收集原木','奖励','打开指南','\u2028']) and '\\u2028' not in quest.read_text())
check('FTB-nontext-structure-preserved',all(t in quest.read_text() for t in ['// preserve this comment','Q_0123','minecraft:oak_log','count: 5L','command: "say unchanged"']))
check('FTB-native-English-untouched',oldlang.read_bytes()==before[oldlang] and modern.read_bytes()==before[modern])
check('existing-Chinese-extra-and-missing-list-line-preserved',all(t in zh.read_text() for t in ['已有标题','已有第一行','现代第二行','额外中文保留']))
newlocale=run/'config/ftbquests/quests/lang/zh_cn/chapters/start.json5';check('new-native-locale-generated',json.loads(newlocale.read_text())['title.BBB']=='新版本标题')
with zipfile.ZipFile(pack) as z:
 text=z.read('data/story/functions/welcome.mcfunction').decode();check('function-text-only-changed','欢迎 ' in text and '旅行者' in text and '第一章' in text and '"translate":"story.key"' in text and 'give @s minecraft:diamond 3' in text and 'say DO NOT TRANSLATE' in text)
 a=json.loads(z.read('data/story/advancements/start.json'));check('advancement-condition-and-reward-preserved',a['display']['title']['text']=='新的开始' and a['criteria']==adv['criteria'] and a['rewards']==adv['rewards'])
 check('unrelated-datapack-bytes-preserved',z.read('data/story/loot_tables/rewards.json')==originals['data/story/loot_tables/rewards.json'])
with zipfile.ZipFile(applied['backup']) as z:check('backup-CRC-and-exact-originals',z.testzip() is None and z.read('config/ftbquests/quests/chapters/start.snbt')==before[quest] and z.read('saves/Demo/datapacks/story.zip')==before[pack] and 'config/ftbquests/quests/lang/zh_cn/chapters/start.json5' in z.read('MC-Harbor-backup.json').decode())
check('folder-datapack-applied',json.loads(folder.read_text())['display']['title']=='文件夹标题')
check('KJS-and-original-account-data-unmodified',kjs.read_bytes()==before[kjs])
reject('stale-workspace-cannot-overwrite','langApply',project=path,selected=selected)
rescan=call('langScan');fr=call('langRead',project=path,resource=ftb['id'])['entries'];check('English-and-Chinese-retained-after-rescan',any(e['source']=='First Steps' and e['translation']=='第一步' for e in fr))
modern.write_text(modern.read_text().replace('Newest title','Changed upstream title'))
reject('changed-native-English-source-rejected','langExport',project=path,selected=[ftb['id']],packName='Stale',packFormat=15,output=output('stale.zip'))
check('changed-source-rejection-keeps-Chinese',json.loads(newlocale.read_text())['title.BBB']=='新版本标题')
report=dict(passed=sum(checks.values()),failed=sum(not v for v in checks.values()),checks=checks,realPlayerDataModified=False,FTBGameRuntimeTested=False)
(r/'evidence/text-assets-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps({k:report[k] for k in ['passed','failed']},indent=2));raise SystemExit(bool(report['failed']))
