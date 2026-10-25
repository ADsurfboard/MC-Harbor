// MC Harbor friends API, GPL-3.0-or-later. No game traffic or private game accounts pass through it.
const encoder = new TextEncoder();
const profileFields = 'id,code,name,sharing,skin_hash,skin_model';
const digest = async data => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', typeof data === 'string' ? encoder.encode(data) : data)), b => b.toString(16).padStart(2,'0')).join('');
const randomHex = length => Array.from(crypto.getRandomValues(new Uint8Array(length)), b=>b.toString(16).padStart(2,'0')).join('');
const profile = row => ({id:row.id,code:row.code,name:row.name,sharing:!!row.sharing,skinHash:row.skin_hash,skinModel:row.skin_model});
class Failure extends Error {constructor(status,message){super(message);this.status=status;}}
const requireValue=(condition,message,status=400)=>{if(!condition)throw new Failure(status,message);};
const text=(body,key,max,required=false)=>{const value=body[key]??'';requireValue(typeof value==='string' && value.length<=max && !/[\x00-\x1f]/.test(value),'Invalid '+key);const trimmed=value.trim();requireValue(!required || trimmed.length>0,key+' required');return trimmed;};
const json=(value,status=200)=>Response.json(value,{status,headers:{'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
const pair=(a,b)=>[a,b].sort();
const rate=new Map();
function throttle(key,max,window){const now=Date.now();let item=rate.get(key);if(!item || item.until<now){item={until:now+window,count:0};rate.set(key,item);}requireValue(++item.count<=max,'请求过快，请稍后再试。',429);if(rate.size>5000)rate.delete(rate.keys().next().value);}

async function dispatch(request,env){
 const url=new URL(request.url),path=url.pathname,method=request.method;
 if(path==='/health' && method==='GET')return json({ok:true,version:'1.5.0',service:'MC Harbor Friends',chat:true,realtime:!!env.CHAT_HUB});
 const ip=request.headers.get('CF-Connecting-IP')??'local';
 throttle(ip+':all',180,60_000);
 /** @type {Record<string, any>} */ let body={};if(['POST','PUT'].includes(method)){
  requireValue(Number(request.headers.get('Content-Length')??0)<=131_072,'Body too large',413);
  const reader=request.body?.getReader();let bytes=0,parts=[];
  if(reader){while(true){const chunk=await reader.read();if(chunk.done)break;bytes+=chunk.value.length;if(bytes>131_072){await reader.cancel();throw new Failure(413,'Body too large');}parts.push(chunk.value);}}
  const data=new Uint8Array(bytes);let offset=0;for(const part of parts){data.set(part,offset);offset+=part.length;}
  try{body=JSON.parse(new TextDecoder().decode(data));}catch{throw new Failure(400,'Invalid JSON');}
  requireValue(body && typeof body==='object' && !Array.isArray(body),'JSON object required');
 }
 const db=env.DB,q=(sql,...values)=>db.prepare(sql).bind(...values);
 if(path==='/v1/register' && method==='POST'){
  throttle(ip+':register',8,3_600_000);
  const name=text(body,'name',40,true),id=crypto.randomUUID(),code=randomHex(6).toUpperCase(),token=randomHex(48);
  await q('INSERT INTO users(id,code,name,token_hash,created) VALUES(?,?,?,?,?)',id,code,name,await digest(token),Date.now()/1000).run();return json({token},201);
 }
 const token=(request.headers.get('Authorization')??'').replace(/^Bearer /,'');
 requireValue(token.length>=32 && token.length<=256,'Authentication required',401);
 const me=await q('SELECT '+profileFields+' FROM users WHERE token_hash=?',await digest(token)).first();requireValue(me,'Authentication required',401);
 const uid=me.id;
 const notify=async(id,event)=>{if(!env.CHAT_HUB)return;try{const hub=env.CHAT_HUB.get(env.CHAT_HUB.idFromName(id));await hub.fetch(new Request('https://internal/events',{method:'POST',body:JSON.stringify(event)}));}catch{ /* Clients retain authenticated refresh when live transport is unavailable. */ }};
 const links=async()=>{const {results}=await q('SELECT a,b,sender,accepted FROM friendships WHERE a=? OR b=?',uid,uid).all();return results;};
 const allowed=async()=>new Set((await links()).filter(x=>x.accepted).map(x=>x.a===uid?x.b:x.a));
 const isFriend=async other=>{const [a,b]=pair(uid,other);return !!await q('SELECT 1 AS yes FROM friendships WHERE a=? AND b=? AND accepted=1',a,b).first();};
 if(path==='/v1/live' && method==='GET'){
  requireValue(request.headers.get('Upgrade')?.toLowerCase()==='websocket','WebSocket required',426);requireValue(env.CHAT_HUB,'实时连接暂不可用，请使用刷新。',503);
  const hub=env.CHAT_HUB.get(env.CHAT_HUB.idFromName(uid));return hub.fetch(new Request('https://internal/connect',{headers:{'Upgrade':'websocket','X-Harbor-Identity':uid}}));
 }
 if(path==='/v1/inbox' && method==='GET'){
  const {results}=await q('SELECT CASE WHEN f.a=? THEN f.b ELSE f.a END AS peer,m.id,m.sender,m.created FROM friendships f JOIN messages m ON m.a=f.a AND m.b=f.b AND m.id=(SELECT id FROM messages WHERE a=f.a AND b=f.b AND expires>? ORDER BY created DESC,id DESC LIMIT 1) WHERE f.accepted=1 AND (f.a=? OR f.b=?)',uid,Date.now()/1000,uid,uid).all();return json(results);
 }
 if(path.startsWith('/v1/messages/')){
  const other=path.slice('/v1/messages/'.length);requireValue(/^[a-f0-9-]{36}$/i.test(other),'Invalid friend');requireValue(await isFriend(other),'双方确认为好友后才可以聊天。',403);const [a,b]=pair(uid,other),now=Date.now()/1000;
  const decode=row=>({...row,invite:row.invite?JSON.parse(row.invite):null});
  if(method==='GET'){
   const before=Number(url.searchParams.get('before')??(now+1));requireValue(Number.isFinite(before) && before>0,'Invalid cursor');
   const {results}=await q('SELECT id,sender,kind,text,invite,created,expires FROM messages WHERE a=? AND b=? AND created<? AND expires>? ORDER BY created DESC LIMIT 100',a,b,before,now).all();return json(results.map(decode).reverse());
  }
  if(method==='POST'){
   throttle(uid+':chat',60,60_000);const id=text(body,'id',36,true);requireValue(/^[a-f0-9-]{36}$/i.test(id),'Invalid message id');
   const kind=body.kind??'text';requireValue(['text','invite'].includes(kind),'Invalid message type');const message=body.text??'';requireValue(typeof message==='string' && message.length<=2000 && !/[\x00-\x08\x0b-\x1f]/.test(message),'消息最多 2000 个字符。');requireValue(kind==='invite' || message.trim().length>0,'请输入消息。');let invite='';
   if(kind==='invite'){const item=body.invite;requireValue(item && typeof item==='object','Invalid invitation');const transport=text(item,'transport',20,true),target=text(item,'target',260,true);requireValue(['terracotta','address'].includes(transport) && !/\s/.test(target),'Invalid invitation target');invite=JSON.stringify({transport,target,instance:text(item,'instance',200),version:text(item,'version',80),loader:text(item,'loader',80)});}
   const expires=now+(kind==='invite'?1800:30*86400);
   await q('INSERT OR IGNORE INTO messages(a,b,id,sender,kind,text,invite,created,expires) SELECT ?,?,?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM friendships WHERE a=? AND b=? AND accepted=1)',a,b,id,uid,kind,message,invite,now,expires,a,b).run();
   const saved=await q('SELECT id,sender,kind,text,invite,created,expires FROM messages WHERE a=? AND b=? AND id=?',a,b,id).first();requireValue(saved && saved.sender===uid,'好友关系已变更或消息编号重复。',409);await notify(other,{type:'chat',peer:uid});await notify(uid,{type:'chat',peer:other});return json(decode(saved),201);
  }
 }
 if(path==='/v1/friends' && method==='GET'){
  const result={me:profile(me),friends:[],requests:[],sent:[]};
  const {results}=await q('SELECT u.'+profileFields.split(',').join(',u.')+',f.sender,f.accepted FROM friendships f JOIN users u ON u.id=CASE WHEN f.a=? THEN f.b ELSE f.a END WHERE f.a=? OR f.b=?',uid,uid,uid).all();
  for(const row of results){const key=row.accepted?'friends':row.sender===uid?'sent':'requests';result[key].push(profile(row));}return json(result);
 }
 if(path==='/v1/friends/request' && method==='POST'){
  const other=await q('SELECT id FROM users WHERE code=?',text(body,'code',12,true).toUpperCase()).first();requireValue(other,'好友码不存在。',404);requireValue(other.id!==uid,'不能添加自己。');requireValue((await links()).length<300,'好友数量已达上限。',409);const incoming=await q('SELECT COUNT(*) AS total FROM friendships WHERE a=? OR b=?',other.id,other.id).first();requireValue(incoming.total<300,'对方好友申请已达上限，请稍后再试。',409);
  const [a,b]=pair(uid,other.id);await q('INSERT OR IGNORE INTO friendships(a,b,sender) VALUES(?,?,?)',a,b,uid).run();await notify(other.id,{type:'friends',peer:uid});return json({ok:true});
 }
 if(path==='/v1/friends/respond' && method==='POST'){
  const [a,b]=pair(uid,text(body,'id',36,true));const link=await q('SELECT sender,accepted FROM friendships WHERE a=? AND b=?',a,b).first();requireValue(link && link.sender!==uid && !link.accepted,'没有可处理的申请。',403);
  await(body.accept===true?q('UPDATE friendships SET accepted=1 WHERE a=? AND b=?',a,b):q('DELETE FROM friendships WHERE a=? AND b=?',a,b)).run();await notify(a===uid?b:a,{type:'friends',peer:uid});return json({ok:true});
 }
 if(path.startsWith('/v1/friends/') && method==='DELETE'){const [a,b]=pair(uid,path.slice('/v1/friends/'.length));await q('DELETE FROM friendships WHERE a=? AND b=?',a,b).run();await notify(a===uid?b:a,{type:'friends',peer:uid});return json({ok:true});}
 if(path==='/v1/me' && method==='PUT'){
  const statements=[];
  if('sharing' in body){requireValue(typeof body.sharing==='boolean','Invalid sharing setting');statements.push(q('UPDATE users SET sharing=? WHERE id=?',body.sharing?1:0,uid));if(!body.sharing)statements.push(q('DELETE FROM history WHERE owner=?',uid));}
  if(body.clearSkin===true)statements.push(q("UPDATE users SET skin=NULL,skin_hash='' WHERE id=?",uid));
  if('skin' in body){
   let raw;try{requireValue(typeof body.skin==='string' && body.skin.length<5_400_000,'Invalid skin');raw=Uint8Array.from(atob(body.skin),x=>x.charCodeAt(0));}catch{throw new Failure(400,'Invalid skin');}
   requireValue(raw.length>=24 && raw.length<=4_000_000 && [137,80,78,71,13,10,26,10].every((v,i)=>raw[i]===v),'Invalid PNG skin');const view=new DataView(raw.buffer);requireValue(view.getUint32(16)===64 && [32,64].includes(view.getUint32(20)),'Standard Minecraft skin required');requireValue(['default','slim'].includes(body.skinModel??'default'),'Invalid skin model');
   // Bound ancillary PNG data so shared skins stay within D1 value and free CPU limits.
   requireValue(raw.length<=65_536,'共享皮肤文件包含过多附加数据，请重新保存标准 PNG 后分享。');statements.push(q('UPDATE users SET skin=?,skin_hash=?,skin_model=? WHERE id=?',raw.buffer,await digest(raw),body.skinModel??'default',uid));
  }
  if(statements.length)await db.batch(statements);return json({ok:true});
 }
 if(path==='/v1/history' && method==='PUT'){
  requireValue(me.sharing,'Sharing disabled',403);const entries=body.entries??[body];requireValue(Array.isArray(entries) && entries.length<=25,'最多一次同步 25 条游戏记录。');const friends=await allowed(),statements=[];let existing=new Set();if(entries.length){const ids=entries.map(entry=>text(entry,'id',36,true));const {results}=await q('SELECT id FROM history WHERE owner=? AND id IN ('+ids.map(()=>'?').join(',')+')',uid,...ids).all();existing=new Set(results.map(x=>x.id));}
  for(const entry of entries){
   requireValue(entry && typeof entry==='object' && !Array.isArray(entry),'Invalid history entry');const id=text(entry,'id',36,true);requireValue(/^[a-f0-9-]{36}$/i.test(id),'Invalid session id');
   const instance=text(entry,'instance',200,true),version=text(entry,'version',80),loader=text(entry,'loader',80),world=text(entry,'world',200),started=entry.started,seconds=entry.seconds;
   requireValue(typeof started==='number' && Number.isFinite(started) && started>0 && started<=Date.now()/1000+300,'Invalid session time');requireValue(Number.isInteger(seconds) && seconds>=0 && seconds<=31_536_000,'Invalid duration');const requested=entry.friends??[];requireValue(Array.isArray(requested) && requested.length<=100,'Invalid companion list');
   const companions=[...new Set(requested.filter(x=>typeof x==='string' && friends.has(x)))];
   statements.push(q('INSERT INTO history VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(owner,id) DO UPDATE SET instance=excluded.instance,version=excluded.version,loader=excluded.loader,world=excluded.world,started=excluded.started,seconds=excluded.seconds,friends=excluded.friends',uid,id,instance,version,loader,world,started,seconds,JSON.stringify(companions)));
  }
  if(entries.some(entry=>!existing.has(entry.id)))statements.push(q('DELETE FROM history WHERE owner=? AND id NOT IN (SELECT id FROM history WHERE owner=? ORDER BY started DESC LIMIT 1000)',uid,uid));if(statements.length)await db.batch(statements);return json({ok:true,saved:entries.length});
 }
 if(path.startsWith('/v1/history/') && method==='GET'){
  const other=path.slice('/v1/history/'.length);requireValue(uid===other || await isFriend(other),'Mutual friendship required',403);const person=await q('SELECT sharing FROM users WHERE id=?',other).first();requireValue(person,'Not found',404);if(!person.sharing)return json([]);
  const friends=await allowed();const {results}=await q('SELECT id,instance,version,loader,world,started,seconds,friends FROM history WHERE owner=? ORDER BY started DESC LIMIT 100',other).all();for(const row of results)row.friends=JSON.parse(row.friends).filter(x=>x===uid || friends.has(x));return json(results);
 }
 if(path.startsWith('/v1/skin/') && method==='GET'){
  const other=path.slice('/v1/skin/'.length);requireValue(uid===other || await isFriend(other),'Mutual friendship required',403);const person=await q('SELECT skin FROM users WHERE id=?',other).first();requireValue(person?.skin,'No shared skin',404);return new Response(new Uint8Array(person.skin),{headers:{'Content-Type':'image/png','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
 }
 if(path==='/v1/me' && method==='DELETE'){await q('DELETE FROM users WHERE id=?',uid).run();await notify(uid,{type:'deleted'});return json({ok:true});}
 throw new Failure(404,'Endpoint not found');
}

export default {async scheduled(_event,env){await env.DB.prepare('DELETE FROM messages WHERE rowid IN (SELECT rowid FROM messages WHERE expires<? ORDER BY expires LIMIT 5000)').bind(Date.now()/1000).run();},async fetch(request,env){try{return await dispatch(request,env);}catch(error){return json({error:error instanceof Failure?error.message:'服务暂时不可用，请稍后重试。'},error instanceof Failure?error.status:503);}}};

// Hibernating per-user notification hub. Chat text and account credentials never enter it.
export class ChatHub {
 constructor(state,_env){this.state=state;}
 async fetch(request){
  const path=new URL(request.url).pathname;
  if(path==='/connect' && request.headers.get('Upgrade')?.toLowerCase()==='websocket'){
   const sockets=this.state.getWebSockets();if(sockets.length>=4){try{sockets[0].close(1000,'Newer connection');}catch{}}
   const [client,server]=Object.values(new WebSocketPair());this.state.acceptWebSocket(server);server.serializeAttachment({id:request.headers.get('X-Harbor-Identity')});server.send(JSON.stringify({type:'ready'}));return new Response(null,{status:101,webSocket:client});
  }
  if(path==='/events' && request.method==='POST'){
   const raw=await request.text();if(raw.length>1024)return new Response('Too large',{status:413});let value;try{value=JSON.parse(raw);}catch{return new Response('Invalid event',{status:400});}
   if(!['chat','friends','deleted'].includes(value.type))return new Response('Invalid event',{status:400});
   const event=JSON.stringify({type:value.type,peer:typeof value.peer==='string'?value.peer:''});let delivered=0;
   for(const socket of this.state.getWebSockets()){try{socket.send(event);delivered++;if(value.type==='deleted')socket.close(1008,'Identity removed');}catch{}}
   return Response.json({delivered});
  }
  return new Response('Not found',{status:404});
 }
 async webSocketMessage(socket,_message){socket.close(1008,'Receive-only notifications');}
 async webSocketClose(socket,code,reason){socket.close(code,reason);}
 async webSocketError(socket){try{socket.close(1011,'Connection interrupted');}catch{}}
}
