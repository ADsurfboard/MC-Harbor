"""Production backend checks in an isolated, disposable fixture; never edits player data."""
from pathlib import Path
import hashlib, json, os, shutil, subprocess, zipfile

root=Path(__file__).resolve().parent.parent
data=root/'evidence/instance-resources-data';data.mkdir(parents=True,exist_ok=True)
if (data/'private/localization').exists():shutil.rmtree(data/'private/localization')
game=data/'game';run=game/'versions/fixture';run.mkdir(parents=True,exist_ok=True)
original=Path('/Applications/.minecraft')
version=json.loads((original/'versions/1.20.1/1.20.1.json').read_text());version['id']='fixture';version['jar']='fixture'
(run/'fixture.json').write_text(json.dumps(version))
jar=run/'fixture.jar'
if not jar.exists():subprocess.run(['/bin/cp','-c',str(original/'versions/1.20.1/1.20.1.jar'),str(jar)],check=True)
assetID=version['assetIndex']['id'];indexPath=original/f'assets/indexes/{assetID}.json'
index=json.loads(indexPath.read_text());extra='minecraft/lang/zh_cn.json';asset=index['objects'][extra];h=asset['hash']
objects=game/f'assets/objects/{h[:2]}';objects.mkdir(parents=True,exist_ok=True);shutil.copy2(original/f'assets/objects/{h[:2]}/{h}',objects/h)
indexes=game/'assets/indexes';indexes.mkdir(parents=True,exist_ok=True);(indexes/f'{assetID}.json').write_text(json.dumps({'objects':{extra:asset}}))
mods=run/'mods';mods.mkdir(exist_ok=True)
loaderIcon=next((root/'Assets/Loaders').glob('*.png')).read_bytes()
english={'hello':'Welcome, %s! %d items.','ready':'Ready','embedded':'Keep existing','braces':'Value {0} ${name}'}
docs={'assets/harborqa/lang/en_us.json':json.dumps(english).encode(),'assets/harborqa/lang/zh_cn.json':'{"embedded":"已有中文"}'.encode(),'assets/harborqa/lang/de_de.json':b'{"ready":"Bereit"}','assets/harborqa/lang/fr_fr.json':b'{invalid preserved original','assets/legacyqa/lang/en_US.lang':b'legacy.hello=Hello %s\n','assets/jei/lang/en_us.json':b'{"jei.tooltip.show.recipes":"Show Recipes"}','../escape/lang/en_us.json':b'{"bad":"bad"}'}
custom=mods/'harbor-fixture.jar'
with zipfile.ZipFile(custom,'w') as z:
    z.writestr('fabric.mod.json',json.dumps({'schemaVersion':1,'id':'harbor_fixture','version':'1.0.0','name':'Harbor Fixture','icon':'assets/harborqa/logo.png','authors':['QA']}))
    z.writestr('assets/harborqa/logo.png',loaderIcon)
    for name,content in docs.items():z.writestr(name,content)
noicon=mods/'harbor-noicon.jar.disabled'
with zipfile.ZipFile(noicon,'w') as z:z.writestr('fabric.mod.json',json.dumps({'schemaVersion':1,'id':'harbor_noicon','version':'1.0.0','name':'No Icon'}))
for source in (root/'evidence/resource-check-data/game/versions/fixture/mods').glob('*.jar'):shutil.copy2(source,mods/source.name)
shutil.copy2(root/'evidence/native-check-data/addon-target/mods/Jade-1.20.1-Forge-11.13.3.jar',mods/'Jade.jar')
pack=run/'resourcepacks/original.zip';pack.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(pack,'w') as z:z.writestr('pack.png',loaderIcon);z.writestr('assets/packqa/lang/en_us.json',b'{"pack.hello":"Pack source"}')
loose=run/'resourcepacks/folder';loose.mkdir(exist_ok=True);(loose/'pack.png').write_bytes(loaderIcon)
looseLang=run/'kubejs/assets/kubeqa/lang';looseLang.mkdir(parents=True,exist_ok=True);(looseLang/'en_us.json').write_text('{"script.hello":"Script source"}')
checks={};details={};before={p:hashlib.sha256(p.read_bytes()).hexdigest() for p in list(mods.glob('*'))+[pack]}
java='/Library/Java/JavaVirtualMachines/liberica-jdk-21.jdk/Contents/Home/bin/java'
resources=root/'build/MC Harbor.app/Contents/Resources'
cp=os.pathsep.join(map(str,[root/'build/Backend.jar',resources/'HMCLCore.jar',resources/'javafx/*']))
command=[java,'-Xms24m','-Xmx384m','-Dshenggan.headless=true','-Djava.awt.headless=true','-Dhmcl.dir='+str(data/'private'),'-cp',cp,'net.morben.shenggan.NativeBridge']
base={'root':str(game),'runDirectory':str(run),'id':'fixture','version':'1.20.1','loader':'Forge','name':'Fixture'}
def call(action,**args):
    result=subprocess.run(command,input=json.dumps(dict(base,command=action,**args)),capture_output=True,text=True,timeout=230)
    events=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    error=next((event['message'] for event in events if event.get('event')=='error'),None)
    if error or result.returncode:raise RuntimeError(error or result.stderr[-800:])
    return next(event['data'] for event in events if event.get('event')=='result')
def check(name,value):
    checks[name]=bool(value);print(('PASS ' if value else 'FAIL ')+name,flush=True)
def reject(name,action,**args):
    try:call(action,**args);check(name,False)
    except RuntimeError:check(name,True)
def output(name):
    path=data/name
    if path.exists():path.unlink() # Only a previous output of this isolated test.
    return str(path)

local=call('resources',resolve=False);items={Path(item['path']).name:item for item in local['resources']}
check('metadata-logo-original',bool(items[custom.name].get('iconPath')))
check('archive-pack-original',bool(items[pack.name].get('iconPath')))
check('folder-pack-original',bool(items['folder'].get('iconPath')))
check('missing-icon-only-default',items[noicon.name].get('iconPath') is None)
check('unknown-source-disabled',not items[custom.name]['links'])
resolved=call('resources',resolve=True);resolvedItems={Path(item['path']).name:item for item in resolved['resources']}
known=next(item for name,item in resolvedItems.items() if name.startswith('Controlling-'))
check('exact-file-Modrinth-original-link',resolvedItems['Jade.jar']['links'].get('modrinth','').startswith('https://modrinth.com/mod/'))
check('exact-file-CurseForge-original-link','curseforge.com/minecraft/mc-mods/controlling' in known['links'].get('curseforge',''))
check('unrecognized-stays-unlinked',not resolvedItems[custom.name]['links'])
cached=call('resources',resolve=False);check('source-index-survives-reopen',next(i for i in cached['resources'] if Path(i['path']).name==Path(known['path']).name)['links']==known['links'])
details['knownLinks']=known['links'];details['sourceWarnings']=resolved['warnings']

project=call('langScan');projectPath=project['project'];sources=project['sources'];chosen=next(s for s in sources if s['path']==str(custom));selected=[chosen['id']]
check('all-locales-in-source',set(chosen['languages'])=={'en_us','zh_cn','de_de','fr_fr'})
check('unsafe-entry-excluded',chosen['languageFiles']==6)
check('disabled-resource-retained',not items[noicon.name]['enabled'])
check('loose-KubeJS-detected',any(s['name']=='kubejs' for s in sources))
minecraft=next(s for s in sources if s['kind']=='minecraft');check('Minecraft-assets-locale-included','zh_cn' in minecraft['languages'])
check('pack-format-read-from-runtime',project['packFormat']==15)
rows=call('langRead',project=projectPath,resource=chosen['id'])['entries'];entries={e['id']:e for e in rows}
check('embedded-Chinese-preserved',entries['harborqa::embedded']['translation']=='已有中文')
check('missing-Chinese-pending',entries['harborqa::ready']['translation']=='')
saved=call('langSave',project=projectPath,changes=[{'resource':chosen['id'],'entry':'harborqa::hello','translation':'欢迎，%1$s！共 %2$d 件。'},{'resource':chosen['id'],'entry':'harborqa::braces','translation':'值 {0} ${name}'},{'resource':chosen['id'],'entry':'harborqa::ready','translation':'就绪'}])
check('manual-batch-save',saved['saved']==3)
reject('printf-type-change-rejected','langSave',project=projectPath,resource=chosen['id'],entry='harborqa::hello',translation='欢迎 %s %s')
reject('named-placeholder-removal-rejected','langSave',project=projectPath,resource=chosen['id'],entry='harborqa::braces',translation='值')
reject('workspace-traversal-rejected','langRead',project=str(data),resource=chosen['id'])
project=call('langScan');rows=call('langRead',project=projectPath,resource=chosen['id'])['entries'];check('manual-edits-survive-rescan',next(e for e in rows if e['id']=='harborqa::ready')['translation']=='就绪')
raw=call('langExport',project=projectPath,selected=selected,packName='AI 测试资源包',packFormat=15,mode='source',output=output('source-AI.zip'))
with zipfile.ZipFile(raw['path']) as z:
    check('AI-ZIP-CRC',z.testzip() is None)
    check('AI-English-template-untranslated',json.loads(z.read('assets/harborqa/lang/zh_cn.json'))==english)
    originals={name:content for name,content in docs.items() if name.startswith('assets/')}
    check('all-original-lang-bytes-preserved',all(z.read('original-lang/'+chosen['id']+'/'+name)==content for name,content in originals.items()))
    check('AI-catalog-and-instructions',{'AI-translation.json','AI-README.txt'}.issubset(z.namelist()))
    check('partial-selection-only',not any('packqa' in name or 'kubeqa' in name for name in z.namelist()))
translated=call('langExport',project=projectPath,selected=selected,packName='我的汉化包',packFormat=15,output=output('translated.zip'))
with zipfile.ZipFile(translated['path']) as z:
    check('named-pack-metadata',json.loads(z.read('pack.mcmeta'))['pack']['description']=='我的汉化包')
    check('translated-entry-and-embedded',json.loads(z.read('assets/harborqa/lang/zh_cn.json'))['ready']=='就绪')
    check('untranslated-fallback-English',json.loads(z.read('assets/legacyqa/lang/zh_cn.json'))['legacy.hello']=='Hello %s')
    check('no-user-absolute-paths-exported',str(data).encode() not in z.read('MC-harbor-manifest.json'))
reject('export-does-not-overwrite','langExport',project=projectPath,selected=selected,packName='Again',packFormat=15,output=translated['path'])
incoming=data/'incoming.zip'
with zipfile.ZipFile(incoming,'w') as z:z.writestr('assets/harborqa/lang/zh_cn.json',json.dumps({'ready':'已准备','hello':'错误 %d','braces':'值 {0} ${name}'},ensure_ascii=False))
imported=call('langImport',project=projectPath,selected=selected,file=str(incoming));check('AI-pack-import-by-key',imported['imported']==2 and imported['rejected']==1)
legacy=call('langExport',project=projectPath,selected=selected,packName='Legacy',packFormat=3,output=output('legacy.zip'))
with zipfile.ZipFile(legacy['path']) as z:check('legacy-LANG-export','assets/legacyqa/lang/zh_cn.lang' in z.namelist() and 'assets/legacyqa/lang/zh_cn.json' not in z.namelist())
modern=call('langExport',project=projectPath,selected=selected,packName='Modern',packFormat=84,output=output('modern.zip'))
with zipfile.ZipFile(modern['path']) as z:check('modern-format-range',json.loads(z.read('pack.mcmeta'))['pack']['min_format']==[84,0])
communitySource=chosen
community=call('langTranslate',project=projectPath,selected=[communitySource['id']]);check('live-CFPA-community-translation',community['filled']>0 and not community['warnings'])
details['community']={key:community[key] for key in ['filled','pending','warnings']}
communityPack=call('langExport',project=projectPath,selected=[communitySource['id']],packName='Community',packFormat=15,output=output('community.zip'))
with zipfile.ZipFile(communityPack['path']) as z:check('community-attribution-license','CC BY-NC-SA 4.0' in z.read('README.txt').decode())
check('original-resources-unmodified',all(hashlib.sha256(p.read_bytes()).hexdigest()==digest for p,digest in before.items()))
report={'passed':sum(checks.values()),'failed':sum(not value for value in checks.values()),'checks':checks,'details':details,'realPlayerResourcesModified':False,'onlineAccountUploadsPerformed':False}
(root/'evidence/instance-resources-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps({'passed':report['passed'],'failed':report['failed'],'details':details},ensure_ascii=False,indent=2))
raise SystemExit(1 if report['failed'] else 0)
