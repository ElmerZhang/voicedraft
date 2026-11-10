// Opt-in evaluation of the Draft window's long-form Polish variant against a real writing provider.
// Skipped unless VOICEDRAFT_DRAFT_EVAL_REPEATS is set, so `swift test` never calls a provider or reads credentials.
//
//   VOICEDRAFT_DRAFT_EVAL_REPEATS=3 swift test --disable-sandbox --filter DraftEvaluationTests
//
// Optional:
//   VOICEDRAFT_DRAFT_EVAL_ONLY=id1,id2       run only these case ids
//   VOICEDRAFT_POLISH_EVAL_SETTINGS=<path>   settings.json (default ~/Library/Application Support/VoiceDraft/settings.json)
//   VOICEDRAFT_POLISH_EVAL_MODEL=<model>     override the writing profile's model
//   VOICEDRAFT_DRAFT_EVAL_STRICT=1           fail when any case never returns an accepted output or repeats its context
//
// Each case gives the text before and after the insertion point, a dictated passage and accepted outputs. A run
// passes when the finalized output matches an accepted string; it is "clean" when it contains none of the case's
// forbidden substrings (text of the reference context). The API key is read from the login Keychain (service
// com.voicedraft.mac.credentials, account = profile id) and is never printed. The corpus is Fixtures/draft-eval.json.
import Foundation
import XCTest
@testable import VoiceDraftCore

final class DraftEvaluationTests: XCTestCase {
    private struct Corpus: Decodable { var cases: [Case] }
    private struct Case: Decodable {
        var id: String
        var before: String
        var after: String
        var transcript: String
        var accepted: [String]
        var forbidden: [String]
        var note: String?
    }

    private static let requestTimeout: UInt64 = 120_000_000_000

    func testDraftPassageCorpus() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["VOICEDRAFT_DRAFT_EVAL_REPEATS"], let repeats = Int(raw.trimmingCharacters(in: .whitespaces)), repeats > 0 else {
            throw XCTSkip("Set VOICEDRAFT_DRAFT_EVAL_REPEATS to a positive integer to run the draft evaluation.")
        }
        let strict = env["VOICEDRAFT_DRAFT_EVAL_STRICT"] == "1"
        let corpusURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/draft-eval.json")
        var cases = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL)).cases
        if let only = env["VOICEDRAFT_DRAFT_EVAL_ONLY"], !only.isEmpty {
            let ids = Set(only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            cases = cases.filter { ids.contains($0.id) }
        }
        XCTAssertFalse(cases.isEmpty, "No corpus cases selected.")

        let settingsPath = env["VOICEDRAFT_POLISH_EVAL_SETTINGS"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VoiceDraft/settings.json").path
        let settings = try JSONDecoder().decode(SharedSettings.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: (settingsPath as NSString).expandingTildeInPath)))
        guard var profile = settings.profiles.first(where: { $0.id == settings.writingID && $0.role == .writing })
                ?? settings.profiles.first(where: { $0.role == .writing }) else {
            return XCTFail("No writing profile in \(settingsPath).")
        }
        if let model = env["VOICEDRAFT_POLISH_EVAL_MODEL"], !model.isEmpty { profile.model = model }
        let key = try Self.keychainKey(account: profile.id.uuidString)
        guard !key.isEmpty else { return XCTFail("No API key in the Keychain for writing profile \"\(profile.name)\".") }
        let protectedTerms = settings.vocabulary.protectedTypographyTerms
        print("Draft evaluation: profile \"\(profile.name)\", model \(profile.model), \(repeats) repeat(s), \(cases.count) case(s)")

        var totalPasses = 0, totalClean = 0, totalRuns = 0, problems: [String] = []
        for item in cases {
            let accepted = Set(item.accepted.map(PolishEvaluationTests.normalize))
            var passes = 0, clean = 0, outputs: [String] = []
            for _ in 0..<repeats {
                let request = try QwenRequests.writing(profile: profile, key: key, text: item.transcript, mode: .polish, settings: settings,
                                                       application: "VoiceDraft Draft", draft: .passage(before: item.before, after: item.after))
                let output = try await Self.complete(request, profile: profile, key: key)
                let final = PolishEvaluationTests.normalize(PolishOutput.finalize(output, transcript: item.transcript, protectedTerms: protectedTerms))
                if accepted.contains(final) { passes += 1 }
                if !item.forbidden.contains(where: final.contains) { clean += 1 }
                if !outputs.contains(final) { outputs.append(final) }
            }
            totalPasses += passes; totalClean += clean; totalRuns += repeats
            if passes == 0 || clean < repeats { problems.append(item.id) }
            print("\(passes)/\(repeats) accepted, \(clean)/\(repeats) no context repeated  \(item.id)")
            for output in outputs { print("    \(accepted.contains(output) ? "✓" : "✗") \(output.replacingOccurrences(of: "\n", with: "⏎"))") }
        }
        print("TOTAL \(totalPasses)/\(totalRuns) accepted, \(totalClean)/\(totalRuns) no context repeated")
        if strict, !problems.isEmpty { XCTFail("Cases with problems: \(problems.joined(separator: ", "))") }
    }

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
