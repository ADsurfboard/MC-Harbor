"""End-to-end NBT checks against the production bridge; only generated isolated worlds are written."""
from pathlib import Path
import fcntl, gzip, hashlib, json, os, shutil, struct, subprocess, uuid, zipfile, zlib

root=Path(__file__).resolve().parent.parent
fixture=root/'evidence/world-editor-fixture'
if fixture.exists():shutil.rmtree(fixture)
run=fixture/'run';data=fixture/'data';saves=run/'saves';saves.mkdir(parents=True);data.mkdir()
java=Path('/Library/Java/JavaVirtualMachines/liberica-jdk-21.jdk/Contents/Home/bin/java')
cp=os.pathsep.join([str(root/'build/Backend.jar'),'/Applications/稳定版我的世界启动器.jar',*[str(p) for p in Path('/Applications/.hmcl/dependencies/macos-arm64/openjfx').glob('*21.0.8*.jar')]])
checks={}
def check(name,value):
    checks[name]=bool(value);print(('PASS ' if value else 'FAIL ')+name,flush=True)
def call(command='worldRead',world='Fixture',**args):
    request=dict(command=command,runDirectory=str(run),world=world,**args)
    r=subprocess.run([str(java),'-Xmx256m','-Djava.awt.headless=true','-Dhmcl.dir='+str(data),'-cp',cp,'net.morben.shenggan.NativeBridge'],input=json.dumps(request),text=True,capture_output=True,timeout=25)
    events=[json.loads(line) for line in r.stdout.splitlines() if line.startswith('{')]
    errors=[e['message'] for e in events if e.get('event')=='error']
    if r.returncode or errors:raise RuntimeError(errors[0] if errors else r.stderr[-600:])
    return next(e['data'] for e in events if e.get('event')=='result')
def reject(name,**args):
    try:call(**args);check(name,False)
    except RuntimeError:check(name,True)
def string(text):
    b=text.encode();return struct.pack('>H',len(b))+b
def payload(kind,value):
    if kind in [1,2,3,4,5,6]:return struct.pack({1:'>b',2:'>h',3:'>i',4:'>q',5:'>f',6:'>d'}[kind],value)
    if kind==7:return struct.pack('>i',len(value))+value
    if kind==8:return string(value)
    if kind==9:
        t,items=value;return bytes([t])+struct.pack('>i',len(items))+b''.join(payload(t,v) for v in items)
    if kind==10:return b''.join(bytes([t])+string(k)+payload(t,v) for k,(t,v) in value.items())+b'\0'
    if kind in [11,12]:return struct.pack('>i',len(value))+b''.join(struct.pack('>i' if kind==11 else '>q',v) for v in value)
    raise ValueError(kind)
def encode(tags,compression='gzip'):
    raw=b'\x0a\x00\x00'+payload(10,tags)
    return gzip.compress(raw) if compression=='gzip' else zlib.compress(raw) if compression=='zlib' else raw
def decode(path):
    raw=path.read_bytes();raw=gzip.decompress(raw) if raw[:2]==b'\x1f\x8b' else zlib.decompress(raw) if raw[:1]==b'x' else raw
    p=0
    def take(n):
        nonlocal p
        out=raw[p:p+n];p+=n;return out
    def unpack(fmt):return struct.unpack(fmt,take(struct.calcsize(fmt)))[0]
    def text():return take(unpack('>H')).decode()
    def read(t):
        if t in [1,2,3,4,5,6]:return unpack({1:'>b',2:'>h',3:'>i',4:'>q',5:'>f',6:'>d'}[t])
        if t==7:return take(unpack('>i'))
        if t==8:return text()
        if t==9:
            k=unpack('>b');return(k,[read(k) for _ in range(unpack('>i'))])
        if t==10:
            out={}
            while True:
                k=unpack('>b')
                if not k:return out
                name=text();out[name]=(k,read(k))
        if t in [11,12]:return [unpack('>i' if t==11 else '>q') for _ in range(unpack('>i'))]
        raise ValueError(t)
    assert unpack('>b')==10;text();return read(10)
identity=uuid.UUID('034d9923-b5c2-448a-9471-8c70c2444320')
parts=list(struct.unpack('>iiii',identity.bytes))
player={'UUID':(11,parts),'playerGameType':(3,0),'Health':(5,20.0),'foodLevel':(3,20),'foodSaturationLevel':(5,5.0),'XpLevel':(3,3),'XpP':(5,0.2),'XpTotal':(3,29),'abilities':(10,{'mayfly':(1,0),'flying':(1,0),'invulnerable':(1,0),'instabuild':(1,0),'mayBuild':(1,1),'walkSpeed':(5,0.1)}),'Inventory':(9,(10,[{'id':(8,'minecraft:diamond'),'Count':(1,17),'Slot':(1,0)}])),'ForgeCaps':(10,{'private_mod_key':(7,b'\x00\xff\x42')})}
world_data={'LevelName':(8,'原测试存档'),'GameType':(3,0),'Difficulty':(1,2),'hardcore':(1,0),'allowCommands':(1,0),'Time':(4,99999),'DayTime':(4,48030),'DataVersion':(3,3465),'Version':(10,{'Name':(8,'1.20.1')}),'Player':(10,player),'UnknownMod':(10,{'double':(6,1.234),'longs':(12,[2**40,-2**40]),'string':(8,'模组数据保留')})}
def make(name,compression='gzip',values=None):
    path=saves/name;path.mkdir();(path/'level.dat').write_bytes(encode({'Data':(10,values or world_data)},compression));(path/'level.dat_old').write_bytes(b'original-old-level');return path
world=make('Fixture');(world/'playerdata').mkdir();mirror=world/'playerdata'/f'{identity}.dat';mirror.write_bytes(encode(player))
before_level=(world/'level.dat').read_bytes();before_mirror=mirror.read_bytes();before_tree=decode(world/'level.dat')
snapshot=call();check('world-and-player-fields-read',snapshot['values']['name']=='原测试存档' and snapshot['values']['day']==2 and snapshot['values']['hunger']==20)
check('embedded-and-UUID-player-choices',len(snapshot['players'])==2 and snapshot['player']=='local')
for name,changes in [('invalid-hunger',{'hunger':21}),('fractional-day',{'day':1.5}),('negative-XP',{'xpLevel':-1}),('unknown-field',{'inventory':'gone'})]:reject(name,command='worldSave',revision=snapshot['revision'],changes=changes)
check('invalid-edits-never-write',before_level==(world/'level.dat').read_bytes() and before_mirror==mirror.read_bytes())
edited=call('worldSave',revision=snapshot['revision'],changes={'name':'新测试存档','gameMode':1,'difficulty':3,'cheats':1,'day':10,'dayTick':6000,'health':16.5,'hunger':15,'saturation':9.5,'xpLevel':30,'xpProgress':0.5})
values=edited['values'];check('all-requested-fields-round-trip',values['name']=='新测试存档' and values['gameMode']==1 and values['day']==10 and values['dayTick']==6000 and values['health']==16.5 and values['hunger']==15 and values['saturation']==9.5)
check('XP-level-progress-total-consistent',values['xpLevel']==30 and values['xpProgress']==0.5 and values['xpTotal']==1451)
check('dayTime-independent-from-world-age',values['ageTicks']==99999)
new=decode(world/'level.dat')['Data'][1];new_player=new['Player'][1];mirror_player=decode(mirror)
check('embedded-and-file-player-synchronized',new_player==mirror_player)
check('creative-abilities-synchronized',all(new_player['abilities'][1][k][1]==1 for k in ['mayfly','invulnerable','instabuild']))
check('unknown-NBT-and-inventory-preserved',new['UnknownMod']==before_tree['Data'][1]['UnknownMod'] and new_player['Inventory']==player['Inventory'] and new_player['ForgeCaps']==player['ForgeCaps'])
check('old-level-file-never-replaced',(world/'level.dat_old').read_bytes()==b'original-old-level')
with zipfile.ZipFile(edited['backup']) as z:check('backup-exact-original-bytes-and-CRC',z.testzip() is None and z.read('level.dat')==before_level and z.read('playerdata/'+mirror.name)==before_mirror)
reject('stale-form-rejected',command='worldSave',revision=snapshot['revision'],changes={'health':10})
with (world/'session.lock').open('r+b') as lock:
    fcntl.lockf(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    reject('active-world-read-lock-rejected')
    reject('active-world-write-lock-rejected',command='worldSave',revision=edited['revision'],changes={'health':10})
reject('world-traversal-rejected',world='../Fixture')
(saves/'linked-world').symlink_to(world,target_is_directory=True);reject('symlink-world-rejected',world='linked-world')
for compression in ['raw','zlib']:
    w=make(compression,compression);s=call(world=compression);call('worldSave',world=compression,revision=s['revision'],changes={'hunger':17});raw=(w/'level.dat').read_bytes();check(compression+'-compression-preserved',raw[:1]==(b'\x0a' if compression=='raw' else b'x') and decode(w/'level.dat')['Data'][1]['Player'][1]['foodLevel'][1]==17)
legacy=json.loads(json.dumps({})) # An independent deep copy retains all tuple types below.
import copy
legacy=copy.deepcopy(world_data);legacy['Player'][1]['Health']=(2,20)
w=make('Legacy',values=legacy);s=call(world='Legacy');call('worldSave',world='Legacy',revision=s['revision'],changes={'health':12});check('legacy-short-health-type-preserved',decode(w/'level.dat')['Data'][1]['Player'][1]['Health']==(2,12))
split=copy.deepcopy(world_data);split.pop('Player');split['singleplayer_uuid']=(11,parts);w=make('Split',values=split);p=w/'players/data';p.mkdir(parents=True);(p/f'{identity}.dat').write_bytes(encode(player));s=call(world='Split');check('split-modern-player-discovered',s['player']==f'players/data/{identity}.dat');call('worldSave',world='Split',revision=s['revision'],player=s['player'],changes={'health':14});check('split-modern-player-write',decode(p/f'{identity}.dat')['Health']==(5,14.0))
report=dict(passed=sum(checks.values()),failed=sum(not v for v in checks.values()),checks=checks,realPlayerWorldsModified=False)
(root/'evidence/world-editor-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps(dict(passed=report['passed'],failed=report['failed'])));raise SystemExit(1 if report['failed'] else 0)
