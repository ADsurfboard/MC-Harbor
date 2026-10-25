#!/usr/bin/env python3
import base64,hashlib,json,pathlib,time,urllib.request,urllib.error,uuid
base="https://mc-harbor-friends.dinakesidkeiwkkeksos.workers.dev"
if __name__=="__main__":
    checks={}
    def call(path,token=None,body=None,method=None):
        headers={"Content-Type":"application/json","User-Agent":"MC-Harbor-QA/1.5.0"}
        if token:headers["Authorization"]="Bearer "+token
        request=urllib.request.Request(base+path,data=json.dumps(body).encode() if body is not None else None,headers=headers,method=method or ("POST" if body is not None else "GET"))
        try:
            with urllib.request.urlopen(request,timeout=25) as response:
                data=response.read();return response.status,data if response.headers.get_content_type()=="image/png" else json.loads(data)
        except urllib.error.HTTPError as error:return error.code,json.loads(error.read())
    def check(name,condition):checks[name]=bool(condition);print(("PASS " if condition else "FAIL ")+name)
    def me(token):return call("/v1/friends",token)[1]["me"]
    identities=[]
    try:
        check("health",call("/health")[1]["ok"])
        check("auth-required",call("/v1/friends")[0]==401)
        a=call("/v1/register",body={"name":"Alice"})[1]["token"]
        b=call("/v1/register",body={"name":"Bob"})[1]["token"]
        c=call("/v1/register",body={"name":"Eve"})[1]["token"]
        identities=[a,b,c]
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
        check("removed-cannot-get-history",call("/v1/history/"+alice["id"],b)[0]==403)
        check("delete-identity",call("/v1/me",c,method="DELETE")[0]==200 and call("/v1/friends",c)[0]==401)
        out=pathlib.Path(__file__).parents[1]/"evidence/social-cloud-live-report.json"
        out.write_text(json.dumps({"base":base,"passed":sum(checks.values()),"failed":sum(not v for v in checks.values()),"checks":checks},ensure_ascii=False,indent=2))
        assert all(checks.values())
    finally:
        for identity in identities:
            try:call("/v1/me",identity,method="DELETE")
            except Exception:pass
