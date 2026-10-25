#!/usr/bin/env python3
"""MC Harbor friends service. Standard library only. Run behind an HTTPS reverse proxy."""
import base64
import contextlib
import hashlib
import json
import math
import os
import re
import secrets
import sqlite3
import struct
import threading
import time
import uuid
from collections import defaultdict, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit,parse_qs

DATA = Path(os.environ.get("HARBOR_SOCIAL_DATA", "./data"))
DATA.mkdir(mode=0o700, parents=True, exist_ok=True)
DB = DATA / "friends.sqlite3"
LOCK = threading.RLock()
RATE = defaultdict(deque)
MAX_BODY = 6_000_000


def connect():
    db = sqlite3.connect(DB, timeout=15)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    return db


def initialize():
    with connect() as db:
        db.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS users(
            id TEXT PRIMARY KEY, code TEXT UNIQUE NOT NULL, name TEXT NOT NULL,
            token_hash TEXT UNIQUE NOT NULL, sharing INTEGER NOT NULL DEFAULT 0,
            skin BLOB, skin_model TEXT NOT NULL DEFAULT 'default', created REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS friendships(
            a TEXT REFERENCES users(id) ON DELETE CASCADE,
            b TEXT REFERENCES users(id) ON DELETE CASCADE,
            sender TEXT REFERENCES users(id) ON DELETE CASCADE,
            accepted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(a,b), CHECK(a<b)
        );
        CREATE TABLE IF NOT EXISTS history(
            owner TEXT REFERENCES users(id) ON DELETE CASCADE,
            id TEXT NOT NULL, instance TEXT NOT NULL, version TEXT NOT NULL,
            loader TEXT NOT NULL, world TEXT NOT NULL, started REAL NOT NULL,
            seconds INTEGER NOT NULL, friends TEXT NOT NULL,
            PRIMARY KEY(owner,id)
        );
        CREATE INDEX IF NOT EXISTS history_time ON history(owner,started DESC);
        CREATE INDEX IF NOT EXISTS friends_a ON friendships(a,accepted);
        CREATE INDEX IF NOT EXISTS friends_b ON friendships(b,accepted);
        CREATE TABLE IF NOT EXISTS messages(
            a TEXT NOT NULL,b TEXT NOT NULL,id TEXT NOT NULL,sender TEXT REFERENCES users(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,text TEXT NOT NULL,invite TEXT NOT NULL DEFAULT '',created REAL NOT NULL,expires REAL NOT NULL,
            PRIMARY KEY(a,b,id),FOREIGN KEY(a,b) REFERENCES friendships(a,b) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS messages_time ON messages(a,b,created DESC);
        CREATE INDEX IF NOT EXISTS messages_expiry ON messages(expires);
        """)
    os.chmod(DB, 0o600)


class APIError(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message


def text(body, key, length, required=False):
    value = body.get(key, "")
    if not isinstance(value, str) or len(value) > length or any(ord(c) < 32 for c in value):
        raise APIError(400, "Invalid " + key)
    value = value.strip()
    if required and not value:
        raise APIError(400, key + " required")
    return value


def profile(row):
    return {"id": row["id"], "code": row["code"], "name": row["name"],
            "sharing": bool(row["sharing"]),
            "skinHash": hashlib.sha256(row["skin"]).hexdigest() if row["skin"] else "",
            "skinModel": row["skin_model"]}


def are_friends(db, first, second):
    a, b = sorted((first, second))
    return db.execute("SELECT 1 FROM friendships WHERE a=? AND b=? AND accepted=1", (a, b)).fetchone() is not None


class Handler(BaseHTTPRequestHandler):
    server_version = "MCHarborFriends/1.5"

    def log_message(self, *_):
        pass  # Do not log credentials, request bodies, skin files, or gameplay data.

    def do_GET(self): self.handle_api()
    def do_POST(self): self.handle_api()
    def do_PUT(self): self.handle_api()
    def do_DELETE(self): self.handle_api()

    def send(self, code, payload, content_type="application/json"):
        data = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def handle_api(self):
        try:
            self.connection.settimeout(20)
            path = urlsplit(self.path).path
            if path == "/health" and self.command == "GET":
                return self.send(200, {"ok": True, "version": "1.5.0", "chat":True, "realtime":False})
            # Default bind is loopback. The proxy must strip inbound X-Real-IP and set it itself.
            ip = self.client_address[0]
            if os.environ.get("HARBOR_TRUST_PROXY") == "1" and ip in ("127.0.0.1", "::1"):
                ip = self.headers.get("X-Real-IP", ip)[:64]
            register = path == "/v1/register" and self.command == "POST"
            window, limit = (3600, 8) if register else (60, 300)
            with LOCK:
                now = time.monotonic()
                key = (ip, register)
                events = RATE[key]
                while events and events[0] < now - window:
                    events.popleft()
                if len(events) >= limit:
                    raise APIError(429, "Please retry later")
                events.append(now)
                if len(RATE) > 10000:
                    for k in list(RATE):
                        if not RATE[k] or RATE[k][-1] < now - 3600:
                            del RATE[k]
                    while len(RATE) > 10000:
                        RATE.pop(next(iter(RATE)))
            body = {}
            if self.command in ("POST", "PUT"):
                try: size = int(self.headers.get("Content-Length", "-1"))
                except ValueError: raise APIError(400, "Invalid body size")
                if size < 0 or size > MAX_BODY:
                    raise APIError(413, "Body too large")
                try: body = json.loads(self.rfile.read(size))
                except (ValueError, UnicodeError): raise APIError(400, "Invalid JSON")
                if not isinstance(body, dict): raise APIError(400, "JSON object required")
            with LOCK, connect() as db:
                if register:
                    name = text(body, "name", 40, True)
                    identifier, code, token = str(uuid.uuid4()), secrets.token_hex(6).upper(), secrets.token_urlsafe(48)
                    db.execute("INSERT INTO users(id,code,name,token_hash,created) VALUES(?,?,?,?,?)",
                               (identifier, code, name, hashlib.sha256(token.encode()).hexdigest(), time.time()))
                    return self.send(201, {"token": token})
                auth = self.headers.get("Authorization", "")
                token = auth[7:] if auth.startswith("Bearer ") else ""
                if not 32 <= len(token) <= 256: raise APIError(401, "Authentication required")
                me = db.execute("SELECT * FROM users WHERE token_hash=?", (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
                if me is None: raise APIError(401, "Authentication required")
                result = self.dispatch(db, me, path, body)
                if isinstance(result, bytes): return self.send(200, result, "image/png")
                return self.send(201 if path.startswith("/v1/messages/") and self.command=="POST" else 200, result)
        except APIError as error:
            self.send(error.code, {"error": error.message})
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            return
        except Exception:
            self.send(500, {"error": "Internal service error"})

    def dispatch(self, db, me, path, body):
        uid, method = me["id"], self.command
        if path == "/v1/live": raise APIError(503,"This deployment uses authenticated refresh instead of live notifications")
        if path == "/v1/inbox" and method == "GET":
            rows=db.execute("SELECT CASE WHEN f.a=? THEN f.b ELSE f.a END AS peer,m.id,m.sender,m.created FROM friendships f JOIN messages m ON m.a=f.a AND m.b=f.b AND m.id=(SELECT id FROM messages WHERE a=f.a AND b=f.b AND expires>? ORDER BY created DESC,id DESC LIMIT 1) WHERE f.accepted=1 AND (f.a=? OR f.b=?)",(uid,time.time(),uid,uid)).fetchall()
            return [dict(row) for row in rows]
        if path.startswith("/v1/messages/"):
            other=path.removeprefix("/v1/messages/")
            if not are_friends(db,uid,other): raise APIError(403,"Mutual friendship required")
            a,b=sorted((uid,other));now=time.time()
            def message(row):
                value=dict(row);value["invite"]=json.loads(value["invite"]) if value["invite"] else None
                return value
            db.execute("DELETE FROM messages WHERE rowid IN (SELECT rowid FROM messages WHERE expires<? ORDER BY expires LIMIT 200)",(now,))
            if method=="GET":
                try:before=float(parse_qs(urlsplit(self.path).query).get("before",[now+1])[0])
                except (TypeError,ValueError):raise APIError(400,"Invalid cursor")
                if not math.isfinite(before) or before<=0:raise APIError(400,"Invalid cursor")
                rows=db.execute("SELECT id,sender,kind,text,invite,created,expires FROM messages WHERE a=? AND b=? AND created<? AND expires>? ORDER BY created DESC LIMIT 100",(a,b,before,now)).fetchall()
                return list(reversed([message(row) for row in rows]))
            if method=="POST":
                identifier=text(body,"id",36,True)
                try:uuid.UUID(identifier)
                except ValueError:raise APIError(400,"Invalid message id")
                kind=body.get("kind","text");content=body.get("text","")
                if kind not in ("text","invite") or not isinstance(content,str) or len(content)>2000 or any(ord(c)<32 and c not in "\n\t" for c in content):raise APIError(400,"Invalid message")
                if kind=="text" and not content.strip():raise APIError(400,"Empty message")
                invite=""
                if kind=="invite":
                    item=body.get("invite")
                    if not isinstance(item,dict):raise APIError(400,"Invalid invitation")
                    transport,target=text(item,"transport",20,True),text(item,"target",260,True)
                    if transport not in ("terracotta","address") or any(c.isspace() for c in target):raise APIError(400,"Invalid invitation target")
                    invite=json.dumps(dict(transport=transport,target=target,instance=text(item,"instance",200),version=text(item,"version",80),loader=text(item,"loader",80)),ensure_ascii=False)
                db.execute("INSERT OR IGNORE INTO messages VALUES(?,?,?,?,?,?,?,?,?)",(a,b,identifier,uid,kind,content,invite,now,now+(1800 if kind=="invite" else 30*86400)))
                saved=db.execute("SELECT id,sender,kind,text,invite,created,expires FROM messages WHERE a=? AND b=? AND id=?",(a,b,identifier)).fetchone()
                if saved["sender"]!=uid:raise APIError(409,"Duplicate peer message id")
                return message(saved)
        if path == "/v1/friends" and method == "GET":
            result = {"me": profile(me), "friends": [], "requests": [], "sent": []}
            for link in db.execute("SELECT * FROM friendships WHERE a=? OR b=?", (uid, uid)):
                other = link["b"] if link["a"] == uid else link["a"]
                friend = db.execute("SELECT * FROM users WHERE id=?", (other,)).fetchone()
                category = "friends" if link["accepted"] else "sent" if link["sender"] == uid else "requests"
                result[category].append(profile(friend))
            return result
        if path == "/v1/friends/request" and method == "POST":
            code = text(body, "code", 12, True).upper()
            friend = db.execute("SELECT id FROM users WHERE code=?", (code,)).fetchone()
            if friend is None: raise APIError(404, "Friend code not found")
            if friend["id"] == uid: raise APIError(400, "Cannot add yourself")
            if db.execute("SELECT count(*) FROM friendships WHERE a=? OR b=?", (uid, uid)).fetchone()[0] >= 300:
                raise APIError(409, "Friend limit reached")
            a, b = sorted((uid, friend["id"]))
            db.execute("INSERT OR IGNORE INTO friendships(a,b,sender) VALUES(?,?,?)", (a, b, uid))
            return {"ok": True}
        if path == "/v1/friends/respond" and method == "POST":
            other = text(body, "id", 36, True)
            a, b = sorted((uid, other))
            link = db.execute("SELECT * FROM friendships WHERE a=? AND b=?", (a, b)).fetchone()
            if link is None or link["sender"] == uid or link["accepted"]: raise APIError(403, "No incoming request")
            if body.get("accept") is True: db.execute("UPDATE friendships SET accepted=1 WHERE a=? AND b=?", (a, b))
            else: db.execute("DELETE FROM friendships WHERE a=? AND b=?", (a, b))
            return {"ok": True}
        if path.startswith("/v1/friends/") and method == "DELETE":
            other = path.removeprefix("/v1/friends/")
            a, b = sorted((uid, other))
            db.execute("DELETE FROM friendships WHERE a=? AND b=?", (a, b))
            return {"ok": True}
        if path == "/v1/me" and method == "PUT":
            if body.get("clearSkin") is True:
                db.execute("UPDATE users SET skin=NULL WHERE id=?", (uid,))
            if "sharing" in body:
                if not isinstance(body["sharing"], bool): raise APIError(400, "Invalid sharing setting")
                db.execute("UPDATE users SET sharing=? WHERE id=?", (int(body["sharing"]), uid))
                if not body["sharing"]: db.execute("DELETE FROM history WHERE owner=?", (uid,))
            if "skin" in body:
                try: data = base64.b64decode(body["skin"], validate=True)
                except (ValueError, TypeError): raise APIError(400, "Invalid skin")
                if not data.startswith(b"\x89PNG\r\n\x1a\n") or not 24 <= len(data) <= 4_000_000:
                    raise APIError(400, "Invalid PNG skin")
                width, height = struct.unpack(">II", data[16:24])
                if width != 64 or height not in (32, 64): raise APIError(400, "Standard Minecraft skin required")
                model = body.get("skinModel", "default")
                if model not in ("default", "slim"): raise APIError(400, "Invalid skin model")
                db.execute("UPDATE users SET skin=?,skin_model=? WHERE id=?", (data, model, uid))
            return {"ok": True}
        if path == "/v1/history" and method == "PUT":
            if not me["sharing"]: raise APIError(403, "Sharing disabled")
            entries = body.get("entries", [body])
            if not isinstance(entries, list) or len(entries) > 100: raise APIError(400, "Invalid history batch")
            for entry in entries:
                if not isinstance(entry, dict): raise APIError(400, "Invalid history entry")
                identifier = text(entry, "id", 36, True)
                if not re.fullmatch(r"[A-Fa-f0-9-]{36}", identifier): raise APIError(400, "Invalid session id")
                instance, version, loader, world = (text(entry, key, length, key == "instance") for key, length in (("instance", 200), ("version", 80), ("loader", 80), ("world", 200)))
                started, seconds = entry.get("started"), entry.get("seconds")
                if isinstance(started, bool) or not isinstance(started, (int, float)) or not 0 < started <= time.time() + 300:
                    raise APIError(400, "Invalid session time")
                if isinstance(seconds, bool) or not isinstance(seconds, int) or not 0 <= seconds <= 31_536_000:
                    raise APIError(400, "Invalid duration")
                requested = entry.get("friends", [])
                if not isinstance(requested, list) or len(requested) > 100: raise APIError(400, "Invalid friend list")
                companions = list(dict.fromkeys(f for f in requested if isinstance(f, str) and are_friends(db, uid, f)))
                db.execute("INSERT INTO history VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(owner,id) DO UPDATE SET instance=excluded.instance,version=excluded.version,loader=excluded.loader,world=excluded.world,started=excluded.started,seconds=excluded.seconds,friends=excluded.friends",
                           (uid, identifier, instance, version, loader, world, started, seconds, json.dumps(companions)))
            db.execute("DELETE FROM history WHERE owner=? AND id NOT IN (SELECT id FROM history WHERE owner=? ORDER BY started DESC LIMIT 1000)", (uid, uid))
            return {"ok": True, "saved": len(entries)}
        if path.startswith("/v1/history/") and method == "GET":
            other = path.removeprefix("/v1/history/")
            person = db.execute("SELECT sharing FROM users WHERE id=?", (other,)).fetchone()
            if person is None or (uid != other and not are_friends(db, uid, other)):
                raise APIError(403, "Mutual friendship required")
            if not person["sharing"]: return []
            result = []
            for row in db.execute("SELECT * FROM history WHERE owner=? ORDER BY started DESC LIMIT 100", (other,)):
                value = dict(row); value.pop("owner")
                # Do not disclose third parties' ids to someone who is not also their friend.
                value["friends"] = [f for f in json.loads(value["friends"]) if f == uid or are_friends(db, uid, f)]
                result.append(value)
            return result
        if path.startswith("/v1/skin/") and method == "GET":
            other = path.removeprefix("/v1/skin/")
            if uid != other and not are_friends(db, uid, other): raise APIError(403, "Mutual friendship required")
            row = db.execute("SELECT skin FROM users WHERE id=?", (other,)).fetchone()
            if row is None or not row["skin"]: raise APIError(404, "No shared skin")
            return row["skin"]
        if path == "/v1/me" and method == "DELETE":
            db.execute("DELETE FROM users WHERE id=?", (uid,))
            return {"ok": True}
        raise APIError(404, "Endpoint not found")


def main():
    initialize()
    server = ThreadingHTTPServer((os.environ.get("HARBOR_SOCIAL_HOST", "127.0.0.1"), int(os.environ.get("PORT", "8787"))), Handler)
    print("MC Harbor friends service listening on", server.server_address, flush=True)
    with contextlib.suppress(KeyboardInterrupt): server.serve_forever()
    server.server_close()


if __name__ == "__main__": main()
