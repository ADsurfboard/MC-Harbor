"""Use isolated data; read real profiles without uploading or changing real account skins."""
from pathlib import Path
import json,subprocess,uuid,zipfile,struct,os

root=Path(__file__).resolve().parent.parent
data=root/'evidence/enhancement-data';data.mkdir(parents=True,exist_ok=True,mode=0o700)
resources=root/'build/MC Harbor.app/Contents/Resources'
java='/Library/Java/JavaVirtualMachines/liberica-jdk-21.jdk/Contents/Home/bin/java'
classpath=os.pathsep.join(map(str,[root/'build/Backend.jar',resources/'HMCLCore.jar',resources/'javafx/*']))
command=[java,'-Dshenggan.headless=true','-Djava.awt.headless=true','-Dhmcl.dir='+str(data),'-cp',classpath,'net.morben.shenggan.NativeBridge']
def run(request):
    result=subprocess.run(command,input=json.dumps(request),capture_output=True,text=True,timeout=100)
    events=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    error=next((event['message'] for event in events if event.get('event')=='error'),None)
    if error:raise RuntimeError(error)
    if result.returncode:raise RuntimeError('Backend failed with code '+str(result.returncode))
    return next(event['data'] for event in events if event.get('event')=='result'),events
checks={};profiles=[]
accounts,_=run({'command':'migrate','root':'/Applications/.minecraft'})
for account in accounts['accounts']:
    kind=account['metadata']['kind']
    try:
        profile,_=run({'command':'profile','accountType':kind,'account':account})
        image=Path(profile['skinPath']).read_bytes();width,height=struct.unpack('>II',image[16:24]);checks[kind+'-profilePNG']=width>=64 and height in [width,width//2];profiles.append({'kind':kind,'width':width,'height':height,'default':profile['isDefault']})
    except Exception as error:checks[kind+'-profilePNG']=False;profiles.append({'kind':kind,'error':str(error)})
identifier='account:'+str(uuid.uuid4());offline={'hmclMetadata':{'accountID':identifier,'profileName':'HarborSkinQA'},'privateData':{}}
profile,_=run({'command':'profile','accountType':'offline','account':offline});expectedUUID=profile['uuid']
applied,events=run({'command':'applySkin','accountType':'offline','account':offline,'skinFile':profile['skinPath'],'slim':False})
updated=next(event['data'] for event in events if event.get('event')=='accountUpdated')
restored,_=run({'command':'profile','accountType':'offline','account':updated})
checks['offlineSkinPersisted']=not restored['isDefault'] and restored['uuid']==expectedUUID
checks['offlineSkinUsesHMCL']=updated['hmclMetadata']['skin']['type']=='local_file'

world=data/'world.zip'
with zipfile.ZipFile(world,'w') as archive:archive.writestr('Test World/level.dat',b'harbor-world-fixture');archive.writestr('Test World/region/r.0.0.mca',b'region-fixture')
result,_=run({'command':'installWorld','root':str(data/'game'),'runDirectory':str(data/'instance'),'file':str(world),'name':'World QA'})
checks['worldZIPImported']=Path(result['path'],'level.dat').read_bytes()==b'harbor-world-fixture'
bad=data/'bad-world.zip'
with zipfile.ZipFile(bad,'w') as archive:archive.writestr('../escape/level.dat',b'bad')
try:run({'command':'installWorld','root':str(data/'game'),'runDirectory':str(data/'instance'),'file':str(bad),'name':'Bad'});checks['worldTraversalRejected']=False
except RuntimeError:checks['worldTraversalRejected']=not (data/'escape').exists()

for kind,query in [('mod','Jade'),('resourcepack','Faithful'),('shader','Complementary'),('world','Skyblock'),('modpack','Fabulously')]:
    try:
        result,_=run({'command':'cfSearch','kind':kind,'query':query,'version':'','loader':'','root':str(data/'game')});checks['curseforge-'+kind]=bool(result['hits'])
    except Exception as error:checks['curseforge-'+kind]=False;profiles.append({'resource':kind,'error':str(error)})
report={'checks':checks,'profiles':profiles,'passed':sum(checks.values()),'failed':sum(not x for x in checks.values()),'realAccountUploadsPerformed':False}
(root/'evidence/enhancement-report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
raise SystemExit(1 if report['failed'] else 0)
