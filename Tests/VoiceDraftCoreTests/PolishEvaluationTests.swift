// Opt-in Polish evaluation against a real writing provider. Skipped unless VOICEDRAFT_POLISH_EVAL_REPEATS is set,
// so `swift test` never calls a provider or reads credentials.
//
//   VOICEDRAFT_POLISH_EVAL_REPEATS=3 swift test --disable-sandbox --filter PolishEvaluationTests
//
// Optional:
//   VOICEDRAFT_POLISH_EVAL_ONLY=id1,id2      run only these corpus case ids
//   VOICEDRAFT_POLISH_EVAL_SETTINGS=<path>   settings.json (default ~/Library/Application Support/VoiceDraft/settings.json)
//   VOICEDRAFT_POLISH_EVAL_MODEL=<model>     override the writing profile's model
//   VOICEDRAFT_POLISH_EVAL_STRICT=1          fail when any case passes 0 times
//
// The API key is read from the login Keychain (service com.voicedraft.mac.credentials, account = profile id)
// and is never printed. The corpus is Fixtures/polish-eval.json next to this file.
import Foundation
import XCTest
@testable import VoiceDraftCore

final class PolishEvaluationTests: XCTestCase {
    private struct Corpus: Decodable {
        var comparison: String?
        var cases: [Case]
    }

    private struct Case: Decodable {
        var id: String
        var transcript: String
        var accepted: [String]
        var note: String?
    }

    private static let requestTimeout: UInt64 = 120_000_000_000

    func testPolishCorpus() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["VOICEDRAFT_POLISH_EVAL_REPEATS"], let repeats = Int(raw.trimmingCharacters(in: .whitespaces)),
              repeats > 0 else {
            throw XCTSkip("Set VOICEDRAFT_POLISH_EVAL_REPEATS to a positive integer to run the Polish evaluation.")
        }
        let strict = env["VOICEDRAFT_POLISH_EVAL_STRICT"] == "1"

        let corpusURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/polish-eval.json")
        var cases = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL)).cases
        if let only = env["VOICEDRAFT_POLISH_EVAL_ONLY"], !only.isEmpty {
            let ids = Set(only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            let unknown = ids.subtracting(cases.map(\.id))
            XCTAssertTrue(unknown.isEmpty, "Unknown case ids: \(unknown.sorted().joined(separator: ", "))")
            cases = cases.filter { ids.contains($0.id) }
        }
        XCTAssertFalse(cases.isEmpty, "No corpus cases selected.")

        let settingsPath = env["VOICEDRAFT_POLISH_EVAL_SETTINGS"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/VoiceDraft/settings.json").path
        let settings = try JSONDecoder().decode(SharedSettings.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: (settingsPath as NSString).expandingTildeInPath)))
        guard var profile = settings.profiles.first(where: { $0.id == settings.writingID && $0.role == .writing })
                ?? settings.profiles.first(where: { $0.role == .writing }) else {
            return XCTFail("No writing profile in \(settingsPath).")
        }
        if let model = env["VOICEDRAFT_POLISH_EVAL_MODEL"], !model.isEmpty { profile.model = model }
        let key = try Self.keychainKey(account: profile.id.uuidString)
        guard !key.isEmpty else {
            return XCTFail("No API key in the Keychain for writing profile \"\(profile.name)\" (service com.voicedraft.mac.credentials).")
        }
        let protectedTerms = settings.vocabulary.protectedTypographyTerms

        if let first = cases.first {
            let request = try QwenRequests.writing(profile: profile, key: key, text: first.transcript, mode: .polish,
                                                   settings: settings, application: "Example Editor")
            print("Polish evaluation: profile \"\(profile.name)\", model \(profile.model), \(repeats) repeat(s), \(cases.count) case(s)")
            print("Cached prefix: \(Self.cachedPrefixLength(request)) characters")
        }

        var totalPasses = 0, totalRuns = 0, zeroCases: [String] = []
        for item in cases {
            let accepted = Set(item.accepted.map(Self.normalize))
            var passes = 0
            var failures: [String] = []
            for _ in 0..<repeats {
                let request = try QwenRequests.writing(profile: profile, key: key, text: item.transcript, mode: .polish,
                                                       settings: settings, application: "Example Editor")
                let output = try await Self.complete(request, profile: profile, key: key)
                let final = PolishOutput.finalize(output, transcript: item.transcript, protectedTerms: protectedTerms)
                let normalized = Self.normalize(final)
                if accepted.contains(normalized) { passes += 1 } else if !failures.contains(normalized) { failures.append(normalized) }
            }
            totalPasses += passes; totalRuns += repeats
            if passes == 0 { zeroCases.append(item.id) }
            print("\(passes)/\(repeats)  \(item.id)")
            for failure in failures { print("    \(failure.replacingOccurrences(of: "\n", with: "⏎"))") }
        }
        print("TOTAL \(totalPasses)/\(totalRuns)")
        if strict, !zeroCases.isEmpty {
            XCTFail("Cases that never passed: \(zeroCases.joined(separator: ", "))")
        }
    }

    /// Same non-streaming path as the Mac app (adapter conversion and response parsing), bounded per request.
    private static func complete(_ request: URLRequest, profile: ModelProfile, key: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await WritingClient.complete(request, profile: profile, key: key) }
            group.addTask {
                try await Task.sleep(nanoseconds: requestTimeout)
                throw FeatureError("The evaluation request timed out.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Trim; CRLF to LF; collapse each run of newlines plus the spaces and tabs around it to one LF.
    static func normalize(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let collapsed = unified.replacingOccurrences(of: "[ \\t]*\\n[ \\t\\n]*", with: "\n", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Characters in the first system message block (the cacheable prefix); a plain-string system message counts whole.
    private static func cachedPrefixLength(_ request: URLRequest) -> Int {
        guard let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any],
              let messages = body["messages"] as? [[String: Any]],
              let system = messages.first(where: { $0["role"] as? String == "system" }) else { return 0 }
        if let text = system["content"] as? String { return text.count }
        let blocks = system["content"] as? [[String: Any]] ?? []
        return (blocks.first?["text"] as? String)?.count ?? 0
    }

    /// Reads the key with the `security` tool; the value stays in memory only.
    private static func keychainKey(account: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "com.voicedraft.mac.credentials", "-a", account, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
