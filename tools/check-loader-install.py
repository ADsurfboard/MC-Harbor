"""Install vanilla+loader in a disposable library using no proxy environment."""
from pathlib import Path
import ctypes,json,os,shutil,subprocess,tempfile,time
root=Path(__file__).resolve().parent.parent
res=root/'build/MC Harbor.app/Contents/Resources'; java=res/'Runtime/bin/java'
cp=os.pathsep.join(str(p) for p in [res/'Backend.jar',res/'HMCLCore.jar',*sorted((res/'javafx').glob('*.jar'))])
env={k:v for k,v in os.environ.items() if 'proxy' not in k.lower()};env.update(NO_PROXY='*',no_proxy='*')
with tempfile.TemporaryDirectory(prefix='harbor-loader-qa-',dir=root/'build') as tmp:
 path=Path(tmp);game=path/'game';game.mkdir();data=path/'data';data.mkdir()
 seed=os.environ.get('HARBOR_QA_SEED_ROOT')
 if seed:
  seed=Path(seed);version=json.loads((seed/'versions/1.20.1/1.20.1.json').read_text());index_id=version['assetIndex']['id'];index=seed/'assets/indexes'/f'{index_id}.json'
  def clone(source,dest):
   if not source.is_file() or dest.exists():return
   dest.parent.mkdir(parents=True,exist_ok=True)
   libc=ctypes.CDLL(None,use_errno=True)
   if libc.clonefile(os.fsencode(source),os.fsencode(dest),0)!=0:shutil.copy2(source,dest)
  clone(index,game/'assets/indexes'/index.name)
  for item in json.loads(index.read_text())['objects'].values():
   h=item['hash'];clone(seed/'assets/objects'/h[:2]/h,game/'assets/objects'/h[:2]/h)
  for lib in version.get('libraries',[]):
   downloads=lib.get('downloads',{});artifacts=[downloads.get('artifact',{}),*downloads.get('classifiers',{}).values()]
   for artifact in artifacts:
    relative=artifact.get('path','')
    if relative and '..' not in Path(relative).parts:clone(seed/'libraries'/relative,game/'libraries'/relative)
  print('Seeded isolated library using copy-on-write game assets; original files are read-only.',flush=True)
 def run(request,timeout):
  payload={'root':str(game),'source':'auto','threads':8,**request}
  command=[str(java),'-Djava.awt.headless=true','-Dshenggan.headless=true','-Djava.net.useSystemProxies=false','-Dhttp.proxyHost=','-Dhttps.proxyHost=','-DsocksProxyHost=','-Dhmcl.dir='+str(data),'-cp',cp,'net.morben.shenggan.NativeBridge']
  start=time.monotonic();p=subprocess.run(command,input=json.dumps(payload)+'\n',text=True,capture_output=True,timeout=timeout,env=env)
  events=[json.loads(x) for x in p.stdout.splitlines() if x.startswith('{')];result=next((x['data'] for x in events if x.get('event')=='result'),None)
  errors=[x.get('message') for x in events if x.get('event')=='error']
  if p.returncode or result is None:raise RuntimeError(f"{request['command']} {request.get('loader')} failed after {time.monotonic()-start:.1f}s: {errors}; stderr: {p.stderr[-1800:]}")
  return result
 versions={}
 for loader in ('forge','fabric','neoforge'):
  result=run({'command':'loaders','loader':loader,'version':'1.20.1'},120);assert result['versions'];versions[loader]=result['versions'][0];print('PASS mirror-loader-list',loader,versions[loader],flush=True)
 for loader in ('fabric','forge'):
  name='QA-'+loader;result=run({'command':'install','version':'1.20.1','name':name,'loader':loader,'loaderVersion':versions[loader]},600)
  assert result['id']==name and (game/'versions'/name/(name+'.json')).is_file()
  print('PASS mirror-loader-install',loader,versions[loader],flush=True)
