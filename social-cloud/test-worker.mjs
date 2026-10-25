import { DatabaseSync } from 'node:sqlite';
import { readFile, writeFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import worker,{ChatHub} from './worker.mjs';

const sqlite=new DatabaseSync(':memory:');sqlite.exec(await readFile(new URL('./schema.sql',import.meta.url),'utf8'));
let queryCount=0,queryLog=[];
class Statement {
 constructor(sql,values=[]){this.sql=sql;this.values=values.map(x=>x instanceof ArrayBuffer?new Uint8Array(x):x);}
 bind(...values){return new Statement(this.sql,values);}
 statement(){queryCount++;queryLog.push(this.sql);return sqlite.prepare(this.sql);}
 async first(){return this.statement().get(...this.values)??null;}
 async all(){return {results:this.statement().all(...this.values)};}
 async run(){const result=this.statement().run(...this.values);return {success:true,meta:{changes:Number(result.changes)}};}
}
const DB={prepare:sql=>new Statement(sql),async batch(statements){sqlite.exec('BEGIN');try{const values=[];for(const statement of statements)values.push(await statement.run());sqlite.exec('COMMIT');return values;}catch(error){sqlite.exec('ROLLBACK');throw error;}}};
const events=[];const CHAT_HUB={idFromName:id=>id,get:id=>({async fetch(request){events.push({id,event:JSON.parse(await request.text())});return Response.json({delivered:0});}})};
const checks={};let maxQueries=0;
const check=(name,value)=>{checks[name]=!!value;console.log((value?'PASS ':'FAIL ')+name);};
async function call(path,token,body,method){queryCount=0;queryLog=[];const headers={'CF-Connecting-IP':'qa-private','Content-Type':'application/json'};if(token)headers.Authorization='Bearer '+token;const response=await worker.fetch(new Request('https://qa.invalid'+path,{method:method??(body===undefined?'GET':'POST'),headers,body:body===undefined?undefined:JSON.stringify(body)}),{DB,CHAT_HUB});maxQueries=Math.max(queryCount,maxQueries);return [response.status,response.headers.get('Content-Type')?.includes('image/png')?new Uint8Array(await response.arrayBuffer()):await response.json()];}
const me=async token=>(await call('/v1/friends',token))[1].me;
check('health',(await call('/health'))[1].ok);
check('authentication-required',(await call('/v1/friends'))[0]===401);
const a=(await call('/v1/register',null,{name:'Alice'}))[1].token,b=(await call('/v1/register',null,{name:'Bob'}))[1].token,c=(await call('/v1/register',null,{name:'Eve'}))[1].token;
const alice=await me(a),bob=await me(b),eve=await me(c);
check('default-private',!alice.sharing);
check('no-token-in-profile',!JSON.stringify(alice).includes(a));
check('self-friend-rejected',(await call('/v1/friends/request',a,{code:alice.code}))[0]===400);
check('request-sent',(await call('/v1/friends/request',a,{code:bob.code}))[0]===200);
check('pending-is-not-friend',(await call('/v1/history/'+alice.id,b))[0]===403);
check('incoming-request-visible',(await call('/v1/friends',b))[1].requests[0].id===alice.id);
check('sender-cannot-accept',(await call('/v1/friends/respond',a,{id:bob.id,accept:true}))[0]===403);
check('mutual-accept',(await call('/v1/friends/respond',b,{id:alice.id,accept:true}))[0]===200);
check('live-requires-upgrade',(await call('/v1/live',a))[0]===426);
check('chat-stranger-denied',(await call('/v1/messages/'+alice.id,c))[0]===403);
const messageID=crypto.randomUUID(),messageBody={id:messageID,kind:'text',text:'Hello\n你好，朋友'};
check('chat-message-send',(await call('/v1/messages/'+bob.id,a,messageBody))[0]===201);
let conversation=(await call('/v1/messages/'+alice.id,b))[1];
check('chat-preserves-text',conversation[0].text===messageBody.text && conversation[0].sender===alice.id);
const inbox=(await call('/v1/inbox',b))[1];
check('inbox-latest-message',inbox.length===1 && inbox[0].peer===alice.id && inbox[0].id===messageID);
check('inbox-metadata-only',!JSON.stringify(inbox).includes(messageBody.text) && !JSON.stringify(inbox).includes(a));
check('inbox-stranger-empty',(await call('/v1/inbox',c))[1].length===0);
check('chat-idempotent',(await call('/v1/messages/'+bob.id,a,messageBody))[0]===201 && (await call('/v1/messages/'+bob.id,a))[1].length===1);
check('chat-cannot-reuse-peer-id',(await call('/v1/messages/'+alice.id,b,messageBody))[0]===409);
check('chat-blank-refused',(await call('/v1/messages/'+bob.id,a,{id:crypto.randomUUID(),text:'  '}))[0]===400);
check('chat-too-long-refused',(await call('/v1/messages/'+bob.id,a,{id:crypto.randomUUID(),text:'x'.repeat(2001)}))[0]===400);
check('chat-control-refused',(await call('/v1/messages/'+bob.id,a,{id:crypto.randomUUID(),text:'x\u0000y'}))[0]===400);
const invitation={id:crypto.randomUUID(),kind:'invite',text:'一起游玩',invite:{transport:'terracotta',target:'U/QA-ROOM-CODE',instance:'测试整合包',version:'1.20.1',loader:'Forge'}};
const invited=await call('/v1/messages/'+bob.id,a,invitation);
check('invitation-created',invited[0]===201 && invited[1].invite.target===invitation.invite.target && Math.abs(invited[1].expires-invited[1].created-1800)<1);
check('invite-cannot-open-arbitrary-url',(await call('/v1/messages/'+bob.id,a,{...invitation,id:crypto.randomUUID(),invite:{transport:'javascript',target:'alert(1)'}}))[0]===400);
check('notifications-contain-no-chat-content',events.some(x=>x.id===bob.id && x.event.type==='chat') && !JSON.stringify(events).includes(messageBody.text));
sqlite.prepare('UPDATE messages SET expires=? WHERE id=?').run(Date.now()/1000-5,invitation.id);
check('expired-invitation-hidden',!(await call('/v1/messages/'+bob.id,a))[1].some(x=>x.id===invitation.id));
await worker.scheduled({}, {DB});check('expired-chat-pruned',sqlite.prepare('SELECT COUNT(*) AS n FROM messages WHERE id=?').get(invitation.id).n===0);
const socket={sent:[],closed:[],send(value){this.sent.push(JSON.parse(value));},close(code,reason){this.closed.push([code,reason]);}};
const hub=new ChatHub({getWebSockets:()=>[socket]},{});
check('hub-private-route-only',(await hub.fetch(new Request('https://internal/other'))).status===404);
check('hub-event-delivery',(await hub.fetch(new Request('https://internal/events',{method:'POST',body:JSON.stringify({type:'chat',peer:alice.id,token:a,text:'must not forward'})}))).status===200 && !JSON.stringify(socket.sent).includes(a) && !JSON.stringify(socket.sent).includes('must not forward'));
await hub.webSocketMessage(socket,'attempt-send');check('hub-receive-only',socket.closed[0][0]===1008);
const record={id:crypto.randomUUID(),instance:'测试整合包',version:'1.20.1',loader:'Forge',world:'TestWorld',started:Date.now()/1000-3600,seconds:3500,friends:[bob.id,eve.id]};
check('upload-before-consent-rejected',(await call('/v1/history',a,record,'PUT'))[0]===403);
check('consent-on',(await call('/v1/me',a,{sharing:true},'PUT'))[0]===200);
check('history-upload',(await call('/v1/history',a,{entries:[record]},'PUT'))[1].saved===1);
let history=(await call('/v1/history/'+alice.id,b))[1];
check('actual-world-duration-preserved',history[0].world==='TestWorld' && history[0].seconds===3500);
check('unconfirmed-companions-removed',history[0].friends.length===1 && history[0].friends[0]===bob.id);
check('stranger-history-denied',(await call('/v1/history/'+alice.id,c))[0]===403);
check('existing-history-update',(await call('/v1/history',a,{...record,seconds:3550},'PUT'))[0]===200);
check('no-repeated-history-scan',!queryLog.some(sql=>sql.startsWith('DELETE FROM history')));
check('history-idempotent',(await call('/v1/history/'+alice.id,b))[1].length===1);
check('oversized-batch-refused',(await call('/v1/history',a,{entries:Array.from({length:26},()=>({...record,id:crypto.randomUUID()}))},'PUT'))[0]===400);
const valid={...record,id:crypto.randomUUID()},bad={...record,id:crypto.randomUUID(),seconds:-1};
check('invalid-batch-refused',(await call('/v1/history',a,{entries:[valid,bad]},'PUT'))[0]===400);
check('invalid-batch-atomic',(await call('/v1/history/'+alice.id,b))[1].length===1);
const noCompanions={...record,id:crypto.randomUUID()};delete noCompanions.friends;
check('optional-companions-default',(await call('/v1/history',a,noCompanions,'PUT'))[0]===200);
const skin=await readFile(new URL('../Assets/Skins/wide/steve.png',import.meta.url));
check('share-real-skin',(await call('/v1/me',a,{skin:skin.toString('base64'),skinModel:'default'},'PUT'))[0]===200);
check('skin-original-bytes',Buffer.from((await call('/v1/skin/'+alice.id,b))[1]).equals(skin));
check('stranger-skin-denied',(await call('/v1/skin/'+alice.id,c))[0]===403);
check('skin-revoked',(await call('/v1/me',a,{clearSkin:true},'PUT'))[0]===200 && (await call('/v1/skin/'+alice.id,b))[0]===404);
await call('/v1/me',a,{skin:skin.toString('base64'),skinModel:'default'},'PUT');
check('consent-off-clears-history',(await call('/v1/me',a,{sharing:false},'PUT'))[0]===200 && (await call('/v1/history/'+alice.id,b))[1].length===0);
check('remove-friend',(await call('/v1/friends/'+bob.id,a,undefined,'DELETE'))[0]===200);
check('removed-skin-denied',(await call('/v1/skin/'+alice.id,b))[0]===403);
check('chat-cascades-on-unfriend',sqlite.prepare('SELECT COUNT(*) AS n FROM messages').get().n===0);
check('removed-chat-denied',(await call('/v1/messages/'+alice.id,b))[0]===403);
check('inbox-unfriend-revoked',(await call('/v1/inbox',b))[1].length===0);
const cohort=[];for(let i=0;i<24;i++){const id=crypto.randomUUID(),code=String(i).padStart(12,'0'),[x,y]=[alice.id,id].sort();cohort.push(id);sqlite.prepare('INSERT INTO users(id,code,name,token_hash,created) VALUES(?,?,?,?,?)').run(id,code,'Multi QA '+i,'fixture-'+i,Date.now()/1000);sqlite.prepare('INSERT INTO friendships(a,b,sender,accepted) VALUES(?,?,?,1)').run(x,y,id);sqlite.prepare('INSERT INTO messages VALUES(?,?,?,?,?,?,?,?,?)').run(x,y,crypto.randomUUID(),id,'text','Isolated friend '+i,'',Date.now()/1000,Date.now()/1000+60);}
check('multi-24-friends-list',(await call('/v1/friends',a))[1].friends.length===24);
const many=(await call('/v1/inbox',a))[1];check('multi-24-unread-isolation',many.length===24 && new Set(many.map(x=>x.peer)).size===24 && !JSON.stringify(many).includes('Isolated friend'));
check('multi-inbox-bounded-queries',queryCount===2);
for(const id of cohort)sqlite.prepare('DELETE FROM users WHERE id=?').run(id);
check('removed-history-denied',(await call('/v1/history/'+alice.id,b))[0]===403);
check('identity-deletion',(await call('/v1/me',c,undefined,'DELETE'))[0]===200 && (await call('/v1/friends',c))[0]===401);
check('free-D1-query-limit',maxQueries<=50);
const report={passed:Object.values(checks).filter(Boolean).length,failed:Object.values(checks).filter(x=>!x).length,maxD1QueriesPerRequest:maxQueries,checks,environment:'Production Worker fetch handler, real SQLite with D1 API adapter; not a remote deployment'};
await writeFile(new URL('../evidence/social-cloud-report.json',import.meta.url),JSON.stringify(report,null,2));sqlite.close();assert.equal(report.failed,0);
