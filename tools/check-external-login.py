"""Exercise the actual backend against a disposable Yggdrasil server, never a real account."""
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
import json,os,subprocess,tempfile,threading
root=Path(__file__).resolve().parent.parent
res=root/'build/MC Harbor.app/Contents/Resources'
ids=['11111111111111111111111111111111','22222222222222222222222222222222']
profiles=[{'id':ids[0],'name':'TestOne'},{'id':ids[1],'name':'TestTwo'}]
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def send(self,obj,status=200,header=None):
  data=json.dumps(obj).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)))
  if header:self.send_header(*header)
  self.end_headers();self.wfile.write(data)
 def do_GET(self):
  if self.path=='/root/':return self.send({'meta':{'serverName':'fixture'}},header=('X-Authlib-Injector-API-Location','/api/'))
  if self.path=='/api/':return self.send({'meta':{'serverName':'fixture','feature.non_email_login':True},'skinDomains':['localhost']})
  return self.send({},404)
 def do_POST(self):
  obj=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))
  if self.path=='/api/authserver/authenticate':
   if obj.get('password')!='fake-password':return self.send({'error':'ForbiddenOperationException','errorMessage':'denied'},403)
   return self.send({'accessToken':'fixture-token','clientToken':obj['clientToken'],'availableProfiles':profiles})
  if self.path=='/api/authserver/refresh':return self.send({'accessToken':'fixture-refreshed','clientToken':obj['clientToken'],'selectedProfile':obj['selectedProfile']})
  return self.send({},404)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
try:
 with tempfile.TemporaryDirectory(prefix='harbor-auth-') as tmp:
  java=res/'Runtime/bin/java';cp=os.pathsep.join(str(p) for p in [res/'Backend.jar',res/'HMCLCore.jar',*sorted((res/'javafx').glob('*.jar'))])
  def call(**kw):
   request={'command':'externalLogin','server':f'http://127.0.0.1:{server.server_port}/root/','username':'fixture','password':'fake-password',**kw}
   env=os.environ.copy();env['NO_PROXY']='127.0.0.1,localhost';env['no_proxy']=env['NO_PROXY']
   p=subprocess.run([str(java),'-Djava.awt.headless=true','-Dshenggan.headless=true','-Dhmcl.dir='+tmp,'-cp',cp,'net.morben.shenggan.NativeBridge'],input=json.dumps(request)+'\n',text=True,capture_output=True,timeout=35,env=env)
   events=[json.loads(x) for x in p.stdout.splitlines() if x.startswith('{')]
   return p.returncode,events
  code,events=call();assert code==0,(code,events);choices=events[-1]['data']['profiles'];assert len(choices)==2 and choices[1]['name']=='TestTwo';print('PASS api-location-and-multiple-characters')
  code,events=call(profile='22222222-2222-2222-2222-222222222222');assert code==0,(code,events);data=events[-1]['data'];assert data['metadata']['name']=='TestTwo' and data['metadata']['kind']=='authlibInjector';assert data['hmclMetadata']['serverBaseURL'].endswith('/api/');assert data['privateData']['accessToken']=='fixture-refreshed';print('PASS selected-profile-and-credential-serialization')
  code,events=call(password='wrong-password');assert code!=0 and 'wrong-password' not in json.dumps(events);print('PASS rejected-credential-not-disclosed')
  code,events=call(server='file:///etc/passwd');assert code!=0;print('PASS invalid-server-scheme-rejected')
finally:server.shutdown();server.server_close()
