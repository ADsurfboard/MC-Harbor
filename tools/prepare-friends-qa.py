"""Disposable 24-friend UI fixture. Never reads or writes player data or production DBs."""
from pathlib import Path
import hashlib,importlib.util,json,os,secrets,threading,time,uuid

root=Path(__file__).resolve().parent.parent
folder=root/'evidence/friends-multi-qa';folder.mkdir(parents=True,exist_ok=True)
os.environ['HARBOR_SOCIAL_DATA']=str(folder/'server')
spec=importlib.util.spec_from_file_location('social_qa',root/'social-server/server.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);module.initialize()

def identity(name):
    return dict(id=str(uuid.uuid4()),code=secrets.token_hex(6).upper(),name=name,token=secrets.token_urlsafe(48))

config=folder/'identity.json'
if config.exists():
    identities=json.loads(config.read_text())['identities']
else:
    identities=[identity('多好友界面 QA')]
    labels=['一起探索新世界','ABCDEFGHIJKLMNOPQRSTUVWXYZ 1234567890','很长的中文好友昵称用于验证自动省略与布局边界','Alex · 建筑师','Steve · 生存玩家','玩家 🟩 Harbor']
    identities += [identity('QA %02d · %s'%(i+1,labels[i%len(labels)])) for i in range(28)]
    skins=sorted((root/'Assets/Skins').glob('*/*.png'))
    with module.connect() as db:
        for i,user in enumerate(identities):
            skin=skins[i%len(skins)].read_bytes() if i%5 else None
            db.execute('INSERT INTO users VALUES(?,?,?,?,?,?,?,?)',(user['id'],user['code'],user['name'][:40],hashlib.sha256(user['token'].encode()).hexdigest(),int(i%6!=0),skin,'slim' if i%2 else 'default',time.time()))
            user['name']=user['name'][:40]
        owner=identities[0]
        for i,friend in enumerate(identities[1:]):
            a,b=sorted((owner['id'],friend['id']))
            db.execute('INSERT INTO friendships VALUES(?,?,?,?)',(a,b,friend['id'] if i<26 else owner['id'],int(i<24)))
            if i>=24:continue
            for n in range(4):
                db.execute('INSERT INTO history VALUES(?,?,?,?,?,?,?,?,?)',(friend['id'],str(uuid.uuid4()),'QA 整合包 %02d'%i,'1.20.1','Forge','QA 存档 %02d'%n,time.time()-n*7200,900*(n+1),json.dumps([owner['id']] if n%2 else [])))
            db.execute('INSERT INTO messages VALUES(?,?,?,?,?,?,?,?,?)',(a,b,str(uuid.uuid4()),friend['id'],'text','这是好友 %02d 的独立会话。\n切换好友后应保留各自的消息和草稿。'%i,'',time.time(),time.time()+86400))
    config.write_text(json.dumps({'identities':identities},ensure_ascii=False));config.chmod(0o600)

server=module.ThreadingHTTPServer(('127.0.0.1',0),module.Handler)
url='http://127.0.0.1:'+str(server.server_port)
config.write_text(json.dumps({'url':url,'identities':identities},ensure_ascii=False));config.chmod(0o600)
qa=root/'build/MCHarborData/social';qa.mkdir(parents=True,exist_ok=True)
notes={x['id']:('备注 %02d · '%i)+x['name'] for i,x in enumerate(identities[1:25]) if i%3==0}
(qa/'settings.json').write_text(json.dumps({'endpoint':url,'notes':notes},ensure_ascii=False))
print(json.dumps({'url':url,'friends':24,'incoming':2,'sent':2,'fixtureOnly':True}),flush=True)
try:server.serve_forever()
finally:server.server_close()
