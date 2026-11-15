#!/usr/bin/env python3
"""Execute the SAME XCTest test bodies with Foundation-only assertions on CLT.

This does not claim to run XCTest or UIKit. Full XCTest remains mandatory in CI.
Temporary stores and compiler outputs are removed; no player directory is used.
"""
from pathlib import Path
import argparse, re, subprocess, tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--suite', choices=['resources', 'social'], default='resources')
args = parser.parse_args()
test_class = 'ResourceTests' if args.suite == 'resources' else 'SocialTests'
tests = (root / ('HarborCore/Tests/HarborCoreTests/' + test_class + '.swift')).read_text()
names = re.findall(r'    func (test\w+)\(\)([^\{]+)\{', tests)
assert len(names) >= (12 if args.suite == 'resources' else 8)
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
    if args.suite == 'social': production.append(root / 'HarborCore/Sources/HarborCore/SocialClient.swift')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', *map(str, production), str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=90)
