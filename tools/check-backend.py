from pathlib import Path
import subprocess,json,os
root=Path(__file__).resolve().parent.parent
classpath=os.pathsep.join([str(root/'build/Backend.jar'),'/Applications/稳定版我的世界启动器.jar']+[str(p) for p in Path('/Applications/.hmcl/dependencies/macos-arm64/openjfx').glob('*21.0.8*.jar')])
request={'command':'mods','root':'/Applications/.minecraft','id':'冻土','runDirectory':'/Applications/.minecraft/versions/冻土','source':'auto','threads':8}
command=['/Library/Java/JavaVirtualMachines/liberica-jdk-21.jdk/Contents/Home/bin/java','-Xmx256m','-Djava.awt.headless=true','-Dhmcl.dir='+str(root/'evidence/test-data'),'-cp',classpath,'net.morben.shenggan.NativeBridge']
with open(root/'evidence/backend-mods.stderr','w') as stderr:
 result=subprocess.run(command,input=json.dumps(request),text=True,stdout=subprocess.PIPE,stderr=stderr,timeout=40)
(root/'evidence/backend-mods.jsonl').write_text(result.stdout)
print('Exit',result.returncode)
for line in result.stdout.splitlines():
 try:
  obj=json.loads(line)
  if obj.get('event')=='result':print('Mods parsed:',len(obj['data']['mods']));print('Sample:',[{k:m.get(k) for k in ['name','version','authors','enabled']} for m in obj['data']['mods'][:2]])
  elif obj.get('event')=='error':print(obj)
 except ValueError:pass
