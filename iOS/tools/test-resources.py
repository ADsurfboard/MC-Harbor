#!/usr/bin/env python3
"""Execute the SAME XCTest test bodies with Foundation-only assertions on CLT.

This does not claim to run XCTest or UIKit. Full XCTest remains mandatory in CI.
Temporary stores and compiler outputs are removed; no player directory is used.
"""
from pathlib import Path
import argparse, re, subprocess, tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--suite', choices=['resources', 'social', 'history', 'localization'], default='resources')
parser.add_argument('--arch', choices=['host', 'x86_64'], default='host')
args = parser.parse_args()
test_class = {'resources': 'ResourceTests', 'social': 'SocialTests', 'history': 'SocialPlayHistoryTests', 'localization': 'LocalizationTests'}[args.suite]
tests = (root / ('HarborCore/Tests/HarborCoreTests/' + test_class + '.swift')).read_text()
names = re.findall(r'    func (test\w+)\(\)([^\{]+)\{', tests)
assert len(names) >= {'resources': 12, 'social': 8, 'history': 6, 'localization': 11}[args.suite]
tests = tests.replace('import XCTest', 'import Foundation').replace('@testable import HarborCore', '')
shim = r'''
@MainActor class XCTestCase {}
@MainActor enum Checks { static var count = 0 }
@MainActor func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) { fatalError("\(file):\(line): \(message)") }
@MainActor func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    Checks.count += 1; do { if try a() != b() { XCTFail("not equal", file: file, line: line) } } catch { XCTFail("unexpected error: \(error)", file: file, line: line) }
}
@MainActor func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    Checks.count += 1; do { if try !value() { XCTFail("not true", file: file, line: line) } } catch { XCTFail("unexpected error: \(error)", file: file, line: line) }
}
@MainActor func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    Checks.count += 1; do { if try value() { XCTFail("not false", file: file, line: line) } } catch { XCTFail("unexpected error: \(error)", file: file, line: line) }
}
@MainActor func XCTAssertNil<T>(_ value: @autoclosure () -> T?, file: StaticString = #filePath, line: UInt = #line) {
    Checks.count += 1; if value() != nil { XCTFail("not nil", file: file, line: line) }
}
@MainActor func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    Checks.count += 1; do { _ = try value(); XCTFail("did not throw", file: file, line: line) } catch {}
}
@MainActor func XCTAssertNoThrow<T>(_ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    Checks.count += 1; do { _ = try value() } catch { XCTFail("unexpected error: \(error)", file: file, line: line) }
}
@MainActor func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    Checks.count += 1; guard let value else { XCTFail("missing value", file: file, line: line); throw ResourceError.invalid("missing") }; return value
}
'''
calls = '\n'.join(('try ' if 'throws' in signature else '') + ('await ' if 'async' in signature else '') + 'tests.' + name + '()' for name, signature in names)
runner = '\n@main struct Run { @MainActor static func main() async throws { let tests = ' + test_class + '()\n' + calls + '\nprint("PASS: ' + str(len(names)) + ' production test bodies, \\(Checks.count) Foundation assertions; XCTest/UI remain CI gates.")\n} }\n'
with tempfile.TemporaryDirectory(prefix='harbor-resource-checks-') as temporary:
    source = Path(temporary) / 'Checks.swift'; source.write_text(shim + tests + runner)
    binary = Path(temporary) / 'checks'
    production = sorted((root / 'HarborCore/Sources/HarborCore').glob('Resource*.swift'))
    if args.suite == 'localization': production += sorted((root / 'HarborCore/Sources/HarborCore').glob('Localization*.swift'))
    if args.suite in ['social', 'history']: production.append(root / 'HarborCore/Sources/HarborCore/SocialClient.swift')
    if args.suite == 'history': production.append(root / 'HarborCore/Sources/HarborCore/SocialPlayHistory.swift')
    architecture = ['-target', 'x86_64-apple-macos13.0'] if args.arch == 'x86_64' else []
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', *architecture, *map(str, production), str(source), '-o', str(binary)], check=True)
    run = ['arch', '-x86_64', str(binary)] if args.arch == 'x86_64' else [str(binary)]
    subprocess.run(run, check=True, timeout=90)
