#!/usr/bin/env python3
"""Real production Swift client against the isolated existing Python service.

Creates three disposable identities only on localhost. Also verifies that a
cross-origin HTTP redirect never receives an Authorization header. No public
accounts, Keychain items, game credentials or user files are used.
"""
from pathlib import Path
import importlib.util, json, os, subprocess, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = Path(__file__).resolve().parents[1]
swift = r'''
import Foundation
@main struct Check {
    static func main() async throws {
        let endpoint = URL(string: CommandLine.arguments[1])!
        let anonymous = try SocialClient(endpoint: endpoint, allowLoopbackForTests: true)
        let health = try await anonymous.health(); guard health.ok else { throw ResourceError.invalid("health failed") }
        let first = try await anonymous.register(name: "iOS QA A"), second = try await anonymous.register(name: "iOS QA B"), third = try await anonymous.register(name: "iOS QA C")
        let a = try SocialClient(endpoint: endpoint, token: first, allowLoopbackForTests: true)
        let b = try SocialClient(endpoint: endpoint, token: second, allowLoopbackForTests: true)
        let c = try SocialClient(endpoint: endpoint, token: third, allowLoopbackForTests: true)
        let am = try await a.snapshot().me, bm = try await b.snapshot().me
        try await a.request(code: bm.code)
        let pending = try await b.snapshot(); guard pending.requests.count == 1 else { throw ResourceError.invalid("request missing") }
        try await b.respond(id: am.id, accept: true)
        guard try await a.snapshot().friends.count == 1 else { throw ResourceError.invalid("mutual friendship missing") }
        var denied = false
        do { _ = try await c.messages(id: am.id) } catch { denied = true }
        guard denied else { throw ResourceError.invalid("non-friend chat access") }
        let id = UUID()
        _ = try await a.send(id: id, to: bm.id, text: "跨平台中文消息")
        _ = try await a.send(id: id, to: bm.id, text: "跨平台中文消息")
        let rows = try await b.messages(id: am.id)
        guard rows.count == 1, rows.first?.text == "跨平台中文消息" else { throw ResourceError.invalid("message idempotence failed") }
        let invite = SocialInvitation(transport: "address", target: "play.example.com:25565", instance: "QA Fabric", version: "1.20.1", loader: "Fabric")
        _ = try await a.send(id: UUID(), to: bm.id, text: "一起游玩", invite: invite)
        let messages = try await b.messages(id: am.id)
        guard messages.last?.invite == invite else { throw ResourceError.invalid("invite failed") }
        let inbox = try await b.inbox(); guard inbox.contains(where: { $0.peer == am.id }) else { throw ResourceError.invalid("inbox missing") }
        try await a.setSharing(true)
        let play = SocialPlaySession(instance: "QA Fabric", version: "1.20.1", loader: "Fabric", world: "隔离存档", started: Date().timeIntervalSince1970 - 120, seconds: 120, friends: [bm.id])
        try await a.uploadHistory([play])
        let history = try await b.history(id: am.id)
        guard history.count == 1, history.first?.world == "隔离存档", history.first?.friends == [bm.id] else { throw ResourceError.invalid("history failed") }
        let skin = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        try await a.shareSkin(skin, slim: false)
        let downloaded = try await b.skin(id: am.id)
        guard downloaded == skin else { throw ResourceError.invalid("skin changed") }
        try await a.clearSkin()
        denied = false; do { _ = try await b.skin(id: am.id) } catch { denied = true }
        guard denied else { throw ResourceError.invalid("skin revocation failed") }
        try await a.setSharing(false)
        guard try await b.history(id: am.id).isEmpty else { throw ResourceError.invalid("history revocation failed") }
        try await a.remove(id: bm.id)
        denied = false; do { _ = try await b.messages(id: am.id) } catch { denied = true }
        guard denied else { throw ResourceError.invalid("friend revocation failed") }
        let redirect = try SocialClient(endpoint: URL(string: CommandLine.arguments[2])!, token: String(repeating: "a", count: 96), allowLoopbackForTests: true)
        denied = false; do { _ = try await redirect.snapshot() } catch { denied = true }
        guard denied else { throw ResourceError.invalid("cross-origin redirect accepted") }
        try await a.deleteIdentity(); try await b.deleteIdentity(); try await c.deleteIdentity()
        print("PASS: real Swift client registration, mutual friends, non-friend denial, idempotent chat, invitations, inbox, shared history, skins, revocation, identity deletion and redirect refusal; localhost only.")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='harbor-ios-social-checks-') as temporary:
    os.environ['HARBOR_SOCIAL_DATA'] = str(Path(temporary) / 'database')
    spec = importlib.util.spec_from_file_location('isolated_harbor_social', root.parent / 'social-server/server.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); module.initialize()
    server = module.ThreadingHTTPServer(('127.0.0.1', 0), module.Handler)
    seen = []
    class Receiver(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            seen.append(self.headers.get('Authorization')); self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
    receiver = ThreadingHTTPServer(('127.0.0.1', 0), Receiver)
    class Redirect(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            self.send_response(302); self.send_header('Location', f'http://127.0.0.1:{receiver.server_port}/capture'); self.end_headers()
    redirect = ThreadingHTTPServer(('127.0.0.1', 0), Redirect)
    servers = [server, receiver, redirect]
    for item in servers: threading.Thread(target=item.serve_forever, daemon=True).start()
    try:
        source = Path(temporary) / 'Check.swift'; source.write_text(swift)
        binary = Path(temporary) / 'check'
        production = sorted((root / 'HarborCore/Sources/HarborCore').glob('Resource*.swift')) + [root / 'HarborCore/Sources/HarborCore/SocialClient.swift']
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', *map(str, production), str(source), '-o', str(binary)], check=True)
        subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}', f'http://127.0.0.1:{redirect.server_port}', str(root.parent / 'Assets/Skins/wide/steve.png')], check=True, timeout=90)
        assert seen == [], 'The cross-origin receiver was contacted'
        print('PASS: redirect receiver saw zero requests and zero credentials.')
    finally:
        for item in servers: item.shutdown(); item.server_close()
