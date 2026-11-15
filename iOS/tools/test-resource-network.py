#!/usr/bin/env python3
"""Opt-in real catalog -> dependency plan -> disk download -> digest verification.

Uses only a newly created disposable home. No player data or credentials. This
is a host-network Foundation check, not an iPhone/gameplay/China-direct claim.
"""
from pathlib import Path
import argparse, subprocess, tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--allow-network', action='store_true')
args = parser.parse_args()
if not args.allow_network:
    raise SystemExit('Pass --allow-network to contact the public resource services.')
root = Path(__file__).resolve().parents[1]
swift = r'''
import Foundation
@main struct Check {
    static func main() async throws {
        let catalog = ResourceCatalog(route: .domesticFirst)
        let target = ResourceTarget(gameVersion: "1.20.1", loader: "fabric")
        let mr = try await catalog.search("Sodium", source: .modrinth, kind: .mod, target: target)
        guard !mr.projects.isEmpty else { throw ResourceError.invalid("Modrinth search empty") }
        let cf = try await catalog.search("Sodium", source: .curseforge, kind: .mod, target: target)
        guard !cf.projects.isEmpty else { throw ResourceError.invalid("CurseForge search empty") }
        guard let version = try await catalog.versions(project: "uXXizFIs", source: .modrinth, kind: .mod, target: target).first else { throw ResourceError.invalid("No compatible FerriteCore") }
        let plan = try await catalog.plan(version, source: .modrinth, kind: .mod, target: target)
        guard plan.count == 1, plan[0].size < 2_000_000 else { throw ResourceError.invalid("Unexpected network fixture size") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-network-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let destination = home.appendingPathComponent("instance/mods")
        let installer = ResourceInstaller(home: home)
        let count = try await installer.install(plan, kind: .mod, destination: destination, route: .domesticFirst)
        guard count == 1, try ResourceFiles.verify(destination.appendingPathComponent(plan[0].name), file: plan[0]) else { throw ResourceError.invalid("Real installation did not verify") }
        let result: [String: Any] = ["scope": "real host HTTPS and production Foundation client; not iOS gameplay", "modrinthResults": mr.projects.count, "curseforgeResults": cf.projects.count, "file": plan[0].name, "bytes": plan[0].size, "expectedHashes": plan[0].hashes, "installedFiles": count, "shaVerified": true]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
'''
with tempfile.TemporaryDirectory(prefix='harbor-resource-network-') as temporary:
    source = Path(temporary) / 'Check.swift'; source.write_text(swift)
    binary = Path(temporary) / 'check'
    production = sorted((root / 'HarborCore/Sources/HarborCore').glob('Resource*.swift'))
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', *map(str, production), str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=180)
