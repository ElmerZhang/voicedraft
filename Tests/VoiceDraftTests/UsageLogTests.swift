import XCTest
import VoiceDraftCore
@testable import VoiceDraft

final class UsageLogTests: XCTestCase {
    private let profile = ModelProfile(name: "Fixture", role: .writing, endpoint: "https://fixture.invalid/v1/chat/completions",
                                       model: "fixture-model", adapter: .chatCompletions)

    func testAppendsOneLinePerRecordIntoMonthlyFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = UsageLog(directory: directory.appendingPathComponent("Usage"), timeZone: TimeZone(identifier: "UTC")!)
        let october = ISO8601DateFormatter().date(from: "2026-10-15T08:00:00Z")!
        let november = ISO8601DateFormatter().date(from: "2026-11-01T00:00:01Z")!
        log.record(ModelUsageRecord(date: october, kind: .writing, source: .dictationWriting, profile: profile, mode: .polish, streamed: true, latencyMs: 10,
                                    usage: ProviderUsage(inputTokens: 5, outputTokens: 2)))
        log.flush()
        log.record(ModelUsageRecord(date: october.addingTimeInterval(60), kind: .speech, source: .dictationSpeech, profile: profile, streamed: false,
                                    audioSeconds: 3, latencyMs: 20, failure: CancellationError()))
        log.record(ModelUsageRecord(date: november, kind: .learning, source: .vocabularyLearning, profile: profile, streamed: false, latencyMs: 30))
        log.flush()

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Usage").path).sorted()
        XCTAssertEqual(files, ["usage-2026-10.jsonl", "usage-2026-11.jsonl"])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let lines = try String(contentsOf: log.fileURL(for: october)!, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "appends across writes")
        let records = try lines.map { try decoder.decode(ModelUsageRecord.self, from: Data($0.utf8)) }
        XCTAssertEqual(records.map(\.kind), [.writing, .speech])
        XCTAssertEqual(records.map(\.source), [.dictationWriting, .dictationSpeech])
        XCTAssertTrue(lines[0].contains(#""source":"dictation.writing""#))
        XCTAssertEqual(records[0].usage?.inputTokens, 5); XCTAssertEqual(records[1].failure, "cancelled")
        XCTAssertNil(records[0].failureMessage); XCTAssertFalse(lines[0].contains("failureMessage"), "omitted on success")
        XCTAssertEqual(records[1].failureMessage, "CancellationError")
        XCTAssertTrue(lines[1].contains(#""failureMessage":"CancellationError""#))
        XCTAssertEqual(try String(contentsOf: log.fileURL(for: november)!, encoding: .utf8).split(separator: "\n").count, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: log.fileURL(for: november)!.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testWithoutDirectoryWritesNothing() {
        let log = UsageLog(directory: nil)
        XCTAssertNil(log.fileURL(for: Date()))
        log.record(ModelUsageRecord(date: Date(), kind: .writing, source: .studioWriting, profile: profile, streamed: false, latencyMs: 1))
        log.flush()
    }
}
