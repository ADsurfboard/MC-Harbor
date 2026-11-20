#!/usr/bin/env python3
"""Optional live Swift catalog -> integrity-checked PNG smoke on macOS."""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--allow-network', action='store_true')
if not parser.parse_args().allow_network:
    raise SystemExit('Pass --allow-network to contact the public LittleSkin catalog.')

root = Path(__file__).resolve().parents[1] / 'HarborCore/Sources/HarborCore'
main = r'''
import Foundation

@main struct Smoke {
    static func main() async throws {
        let catalog = LittleSkinCatalog()
        let first = try await catalog.search("", page: 1)
        guard first.hasNextPage, let entry = first.items.first(where: { !$0.highResolution }) else {
            throw ResourceError.invalid("The live catalog did not offer a standard skin and a next page.")
        }
        let second = try await catalog.search("", page: 2)
        guard !second.items.isEmpty, first.items.map(\.id) != second.items.map(\.id) else {
            throw ResourceError.invalid("LittleSkin pagination did not advance.")
        }
        let png = try await catalog.texture(entry)
        print("PASS: LittleSkin pages \(first.items.count)/\(second.items.count), indexed model and SHA-256 verified PNG (\(png.count) bytes).")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='harbor-littleskin-') as directory:
    fixture = Path(directory) / 'Smoke.swift'
    fixture.write_text(main)
    executable = fixture.with_suffix('')
    sources = [root / part for part in ('ResourceCatalog.swift', 'ResourceDecoding.swift', 'LittleSkinCatalog.swift')]
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', *map(str, sources),
                    str(fixture), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=115)
