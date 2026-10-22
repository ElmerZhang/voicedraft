import XCTest
@testable import VoiceDraft

final class SharedResultTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("result-\(UUID().uuidString).json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    func testRoundTrip() throws {
        let store = SharedResultStore(fileURL: url)
        XCTAssertNil(store.read())
        // ISO 8601 keeps whole seconds, so use a whole-second date.
        let result = SharedResult(text: "Hello, 世界", mode: "translate", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.write(result)
        XCTAssertEqual(store.read(), result)
    }

    func testLegacyFileWithoutIDOrModeDecodes() throws {
        try Data(#"{"text":"old","createdAt":"2026-01-01T00:00:00Z"}"#.utf8).write(to: url)
        let result = try XCTUnwrap(SharedResultStore(fileURL: url).read())
        XCTAssertEqual(result.text, "old")
        XCTAssertEqual(result.mode, "")
    }

    func testEmptyResultSignalsFinishedTake() throws {
        let store = SharedResultStore(fileURL: url)
        try store.write(text: "", mode: "polish")
        XCTAssertEqual(store.read()?.text, "")
        XCTAssertEqual(store.read()?.mode, "polish")
    }
}
