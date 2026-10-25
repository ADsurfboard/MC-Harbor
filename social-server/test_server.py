#!/usr/bin/env python3
import base64, hashlib, importlib.util, json, os, pathlib, tempfile, threading, time, urllib.request, urllib.error, uuid

with tempfile.TemporaryDirectory(prefix="harbor-social-test-") as folder:
    os.environ["HARBOR_SOCIAL_DATA"] = folder
    spec=importlib.util.spec_from_file_location("harbor_server",pathlib.Path(__file__).with_name("server.py"))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);module.initialize()
    server=module.ThreadingHTTPServer(("127.0.0.1",0),module.Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    base="http://127.0.0.1:"+str(server.server_port)
    checks={}
    def call(path,token=None,body=None,method=None):
        headers={"Content-Type":"application/json"}
        if token:headers["Authorization"]="Bearer "+token
        request=urllib.request.Request(base+path,data=json.dumps(body).encode() if body is not None else None,headers=headers,method=method or ("POST" if body is not None else "GET"))
        try:
            with urllib.request.urlopen(request,timeout=5) as response:
                data=response.read();return response.status,data if response.headers.get_content_type()=="image/png" else json.loads(data)
        except urllib.error.HTTPError as error:return error.code,json.loads(error.read())
    def check(name,condition):checks[name]=bool(condition);print(("PASS " if condition else "FAIL ")+name)
    def me(token):return call("/v1/friends",token)[1]["me"]
    try:
        check("health",call("/health")[1]["ok"])
        check("auth-required",call("/v1/friends")[0]==401)
        a=call("/v1/register",body={"name":"Alice"})[1]["token"]
        b=call("/v1/register",body={"name":"Bob"})[1]["token"]
        c=call("/v1/register",body={"name":"Eve"})[1]["token"]
        alice,bob,eve=me(a),me(b),me(c)
        check("sharing-default-off",not alice["sharing"])
        check("restore-stable-identity",me(a)==alice)
        check("no-token-in-profile","token" not in json.dumps(alice))
        check("no-self-friend",call("/v1/friends/request",a,{"code":alice["code"]})[0]==400)
        check("request",call("/v1/friends/request",a,{"code":bob["code"]})[0]==200)
        check("incoming-request",call("/v1/friends",b)[1]["requests"][0]["id"]==alice["id"])
        check("sender-cannot-accept",call("/v1/friends/respond",a,{"id":bob["id"],"accept":True})[0]==403)
        check("pending-cannot-read",call("/v1/history/"+alice["id"],b)[0]==403)
        check("mutual-accept",call("/v1/friends/respond",b,{"id":alice["id"],"accept":True})[0]==200)
        check("chat-stranger-denied",call("/v1/messages/"+alice["id"],c)[0]==403)
        message={"id":str(uuid.uuid4()),"kind":"text","text":"Hello\n你好"}
        check("chat-send",call("/v1/messages/"+bob["id"],a,message)[0]==201)
        conversation=call("/v1/messages/"+alice["id"],b)[1]
        check("chat-original-text-and-sender",conversation[0]["text"]==message["text"] and conversation[0]["sender"]==alice["id"])
        inbox=call("/v1/inbox",b)[1]
        check("inbox-message-metadata",len(inbox)==1 and inbox[0]["peer"]==alice["id"] and inbox[0]["id"]==message["id"] and message["text"] not in json.dumps(inbox))
        check("inbox-stranger-empty",call("/v1/inbox",c)[1]==[])
        check("chat-idempotent",call("/v1/messages/"+bob["id"],a,message)[0]==201 and len(call("/v1/messages/"+alice["id"],b)[1])==1)
        check("chat-cannot-forge-sender",call("/v1/messages/"+alice["id"],b,message)[0]==409)
        invitation={"id":str(uuid.uuid4()),"kind":"invite","text":"一起玩","invite":{"transport":"terracotta","target":"U/QA-ROOM-CODE","instance":"Pack","version":"1.20.1","loader":"Forge"}}
        sent=call("/v1/messages/"+bob["id"],a,invitation)
        check("chat-room-invitation",sent[0]==201 and sent[1]["invite"]["target"]==invitation["invite"]["target"] and abs(sent[1]["expires"]-sent[1]["created"]-1800)<1)
        check("chat-empty-refused",call("/v1/messages/"+bob["id"],a,{"id":str(uuid.uuid4()),"text":"  "})[0]==400)
        check("chat-long-refused",call("/v1/messages/"+bob["id"],a,{"id":str(uuid.uuid4()),"text":"x"*2001})[0]==400)
        record={"id":str(uuid.uuid4()),"instance":"测试整合包","version":"1.20.1","loader":"Forge","world":"测试存档","started":time.time()-3600,"seconds":3540,"friends":[bob["id"],eve["id"]]}
        check("no-upload-before-opt-in",call("/v1/history",a,record,"PUT")[0]==403)
        check("share-opt-in",call("/v1/me",a,{"sharing":True},"PUT")[0]==200)
        check("upload-history",call("/v1/history",a,{"entries":[record]},"PUT")[1]["saved"]==1)
        history=call("/v1/history/"+alice["id"],b)[1]
        check("friend-receives-game-world-duration",history[0]["world"]=="测试存档" and history[0]["seconds"]==3540)
        check("unconfirmed-companion-filtered",history[0]["friends"]==[bob["id"]])
        check("stranger-cannot-read",call("/v1/history/"+alice["id"],c)[0]==403)
        changed=dict(record,seconds=3601)
        check("idempotent-update",call("/v1/history",a,changed,"PUT")[0]==200 and len(call("/v1/history/"+alice["id"],b)[1])==1)
        bad=dict(record,id=str(uuid.uuid4()),seconds=-1)
        check("negative-duration-rejected",call("/v1/history",a,bad,"PUT")[0]==400)
        first=dict(record,id=str(uuid.uuid4()))
        check("batch-invalid-rejected",call("/v1/history",a,{"entries":[first,bad]},"PUT")[0]==400)
        check("batch-transaction-rolls-back",len(call("/v1/history/"+alice["id"],b)[1])==1)
        # Real bundled PNG, never a player skin or account.
        skin=(pathlib.Path(__file__).parents[1]/"Assets/Skins/wide/steve.png").read_bytes()
        check("skin-share",call("/v1/me",a,{"skin":base64.b64encode(skin).decode(),"skinModel":"default"},"PUT")[0]==200)
        check("skin-hash",me(a)["skinHash"]==hashlib.sha256(skin).hexdigest())
        check("friend-gets-original-skin",call("/v1/skin/"+alice["id"],b)[1]==skin)
        check("stranger-cannot-get-skin",call("/v1/skin/"+alice["id"],c)[0]==403)
        check("revoke-skin",call("/v1/me",a,{"clearSkin":True},"PUT")[0]==200 and call("/v1/skin/"+alice["id"],b)[0]==404)
        call("/v1/me",a,{"skin":base64.b64encode(skin).decode(),"skinModel":"default"},"PUT")
        check("disable-sharing",call("/v1/me",a,{"sharing":False},"PUT")[0]==200 and call("/v1/history/"+alice["id"],b)[1]==[])
        check("remove-friend",call("/v1/friends/"+bob["id"],a,method="DELETE")[0]==200)
        check("removed-cannot-get-skin",call("/v1/skin/"+alice["id"],b)[0]==403)
        check("removed-chat-denied",call("/v1/messages/"+alice["id"],b)[0]==403)
        check("inbox-revoked",call("/v1/inbox",b)[1]==[])
        with module.connect() as db:check("chat-cascades-on-unfriend",db.execute("SELECT count(*) FROM messages").fetchone()[0]==0)
        check("removed-cannot-get-history",call("/v1/history/"+alice["id"],b)[0]==403)
        check("delete-identity",call("/v1/me",c,method="DELETE")[0]==200 and call("/v1/friends",c)[0]==401)
        with module.connect() as db:
            check("stored-token-is-hash",db.execute("SELECT token_hash FROM users WHERE id=?",(alice["id"],)).fetchone()[0]==hashlib.sha256(a.encode()).hexdigest())
        out=pathlib.Path(__file__).parents[1]/"evidence/social-server-report.json";out.write_text(json.dumps({"passed":sum(checks.values()),"failed":sum(not v for v in checks.values()),"checks":checks},indent=2))
        assert all(checks.values())
    finally:server.shutdown();server.server_close();thread.join()
