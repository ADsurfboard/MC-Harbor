"""Run real production clients against an isolated friends service and live public asset APIs."""
from pathlib import Path
import ast,base64,json,os,subprocess,sys,time,urllib.request,uuid

root=Path(__file__).resolve().parent.parent
data=root/'evidence/update-1.5-fixture';data.mkdir(parents=True,exist_ok=True)
server_data=data/'server';server_data.mkdir(exist_ok=True)
environment=os.environ.copy();environment.update(HARBOR_SOCIAL_DATA=str(server_data),PORT='0')
remote=os.environ.get('HARBOR_SOCIAL_TEST_URL','')
server=None if remote else subprocess.Popen([sys.executable,str(root/'social-server/server.py')],env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
identities=[]
try:
    if remote:
        from urllib.parse import urlsplit,urlunsplit
        parts=urlsplit(remote);url=urlunsplit((parts.scheme,parts.netloc.upper(),parts.path,parts.query,parts.fragment))
    else:
        line=server.stdout.readline();address=ast.literal_eval(line[line.index('('):]);url='http://127.0.0.1:'+str(address[1])
    def call(path,token=None,body=None,method=None):
        headers={'Content-Type':'application/json','User-Agent':'MC-Harbor-QA/1.5.0'}
        if token:headers['Authorization']='Bearer '+token
        request=urllib.request.Request(url+'/v1/'+path,data=json.dumps(body).encode() if body is not None else None,headers=headers,method=method or ('POST' if body is not None else 'GET'))
        return json.load(urllib.request.urlopen(request,timeout=25))
    a=call('register',body={'name':'ClientQA'})['token'];identities.append(a);b=call('register',body={'name':'FriendQA'})['token'];identities.append(b)
    alice=call('friends',a)['me'];bob=call('friends',b)['me']
    call('friends/request',a,{'code':bob['code']});call('friends/respond',b,{'id':alice['id'],'accept':True})
    skin=(root/'Assets/Skins/wide/steve.png').read_bytes()
    call('me',b,{'sharing':True,'skin':base64.b64encode(skin).decode(),'skinModel':'default'},'PUT')
    call('history',b,{'id':str(uuid.uuid4()),'instance':'QA Pack','version':'1.20.1','loader':'Forge','world':'TestWorld','started':time.time()-600,'seconds':600,'friends':[alice['id']]},'PUT')
    video=data/'test-wallpaper.mp4'
    subprocess.run(['ffmpeg','-v','error','-y','-f','lavfi','-i','color=c=green:s=320x180:r=1','-t','1','-an','-c:v','libx264','-pix_fmt','yuv420p',str(video)],check=True)
    config=data/'client-test.json';config.write_text(json.dumps({'url':url,'token':a,'friendID':bob['id'],'peerToken':b,'video':str(video)}));config.chmod(0o600)
    client=data/('client-'+str(time.time_ns()));client.mkdir()
    environment=os.environ.copy();environment['SHENGGAN_BACKEND_RESOURCES']=str(root/'build/MC Harbor.app/Contents/Resources')
    result=subprocess.run([str(root/'build/update-checks'),str(config),str(client),str(root/'Assets')],env=environment,timeout=300)
    raise SystemExit(result.returncode)
finally:
    if remote:
        for identity in identities:
            try:call('me',identity,method='DELETE')
            except Exception:pass
    if server:
        server.terminate()
        try:server.wait(timeout=5)
        except subprocess.TimeoutExpired:server.kill();server.wait()
