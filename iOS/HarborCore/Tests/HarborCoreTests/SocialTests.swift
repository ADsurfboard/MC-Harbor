import XCTest
@testable import HarborCore

@MainActor final class SocialTests: XCTestCase {
    private let origin = URL(string: "https://friends.example.com")!
    private let user = "00000000-0000-4000-8000-000000000001"
    private func person(_ index: Int) -> [String: Any] {
        ["id": String(format: "00000000-0000-4000-8000-%012d", index), "code": String(format: "%012d", index), "name": "Friend \(index)", "sharing": true, "skinHash": "", "skinModel": "default"]
    }
    func testInvalidOriginsAndSecretsAreRejectedBeforeRequests() throws {
        for url in ["http://friends.example.com", "https://name:secret@friends.example.com", "https://friends.example.com/v1", "https://friends.example.com?key=secret", "https://friends.example.com#token", "http://127.0.0.1:8787"] {
            XCTAssertThrowsError(try SocialClient(endpoint: URL(string: url)!))
        }
        XCTAssertThrowsError(try SocialClient(endpoint: origin, token: "short"))
        XCTAssertThrowsError(try SocialClient(endpoint: origin, token: String(repeating: "a", count: 96) + "\r\nInjected: yes"))
        XCTAssertNoThrow(try SocialClient(endpoint: URL(string: "http://127.0.0.1:8787")!, allowLoopbackForTests: true))
    }
    func testFortyEightFriendsAndDuplicateIdentityValidation() throws {
        let data = try JSONSerialization.data(withJSONObject: ["me": person(999), "friends": (1...48).map(person), "requests": [], "sent": []])
        let result = try JSONDecoder().decode(SocialSnapshot.self, from: data)
        XCTAssertEqual(result.friends.count, 48); XCTAssertNoThrow(try result.validate())
        let invalid = try JSONSerialization.data(withJSONObject: ["me": person(999), "friends": [person(1), person(1)], "requests": [], "sent": []])
        XCTAssertThrowsError(try JSONDecoder().decode(SocialSnapshot.self, from: invalid).validate())
    }
    func testInvitationsValidateAddressesWithoutOpeningThem() throws {
        for address in ["play.example.com:25565", "[::1]:25565", "192.168.1.2", "minecraft.example"] {
            XCTAssertNoThrow(try SocialInvitation(transport: "address", target: address).validate())
        }
        for address in ["https://example.com", "host:0", "host:70000", "user@host", "host/command", "host\nInjected", "host?token=a"] {
            XCTAssertThrowsError(try SocialInvitation(transport: "address", target: address).validate())
        }
        XCTAssertThrowsError(try SocialInvitation(transport: "shell", target: "command").validate())
    }
    func testHistoryRejectsInventedNonFiniteOrFractionalDuration() throws {
        let valid = SocialPlaySession(instance: "Example", version: "1.20.1", loader: "Fabric", started: 1_700_000_000, seconds: 120)
        XCTAssertNoThrow(try valid.validate())
        for seconds in [-1.0, 0.5, Double.nan, Double.infinity, 31_536_001] {
            XCTAssertThrowsError(try SocialPlaySession(instance: "Example", version: "1.20.1", loader: "Fabric", started: 1_700_000_000, seconds: seconds).validate())
        }
    }
    func testSkinDimensionsAreCheckedBeforeDecodingIncludingDataSlices() {
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13] + Array("IHDR".utf8) + [0, 0, 0, 64, 0, 0, 0, 64] + Array(repeating: 0, count: 9))
        XCTAssertTrue(SocialSkin.hasSafeDimensions(data))
        let offset = Data([0, 0, 0]) + data
        XCTAssertTrue(SocialSkin.hasSafeDimensions(offset.dropFirst(3)))
        data[16] = 255; XCTAssertFalse(SocialSkin.hasSafeDimensions(data))
        XCTAssertFalse(SocialSkin.hasSafeDimensions(Data()))
    }
    func testRegistrationAcceptsCreatedStatusAndValidatesReturnedSecret() async throws {
        let token = String(repeating: "a", count: 96)
        let data = try JSONSerialization.data(withJSONObject: ["token": token])
        let client = try SocialClient(endpoint: origin, transport: { request, _ in
            guard request.value(forHTTPHeaderField: "Authorization") == nil, request.httpMethod == "POST" else { throw ResourceError.invalid("Unexpected request") }
            return ResourceHTTPResult(data: data, status: 201)
        })
        let value = try await client.register(name: "Example"); XCTAssertEqual(value, token)
        let invalid = try SocialClient(endpoint: origin, transport: { _, _ in .init(data: Data(#"{"token":"bad"}"#.utf8), status: 201) })
        do { _ = try await invalid.register(name: "Example"); XCTFail("invalid secret accepted") } catch { }
    }
    func testExpiredMessagesAreFilteredAndPrivatePathsRejected() async throws {
        let value: [String: Any] = ["id": user, "sender": user, "kind": "text", "text": "Example", "created": 10.0, "expires": 20.0]
        let data = try JSONSerialization.data(withJSONObject: [value])
        let client = try SocialClient(endpoint: origin, token: String(repeating: "a", count: 96), transport: { _, _ in .init(data: data, status: 200) })
        let rows = try await client.messages(id: user); XCTAssertTrue(rows.isEmpty)
        do { _ = try await client.messages(id: "../../secrets"); XCTFail("path injection accepted") } catch { }
        let socket = try client.liveRequest()
        XCTAssertEqual(socket.url?.scheme, "wss"); XCTAssertNil(socket.url?.query)
        XCTAssertEqual(socket.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "a", count: 96))
    }
    func testNoAuthenticationAndOversizedMessagesFailLocally() async throws {
        let client = try SocialClient(endpoint: origin, transport: { _, _ in throw ResourceError.invalid("Must not contact the server") })
        do { _ = try await client.snapshot(); XCTFail("anonymous friend list accepted") } catch { }
        do { _ = try await client.send(id: UUID(), to: user, text: String(repeating: "😀", count: 1001)); XCTFail("UTF16 limit ignored") } catch { }
        XCTAssertThrowsError(try client.liveRequest())
    }
}
