import Foundation
import XCTest
@testable import VoiceDraftCore

final class AgentContextScannerTests: XCTestCase {
    func testDefaultHomeIsCurrentUserHome() {
        #if os(macOS)
        XCTAssertEqual(AgentContextScanner.defaultHome.standardizedFileURL.path,
                       FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        #endif
        XCTAssertTrue(AgentContextScanner.defaultHome.hasDirectoryPath)
    }
    private func withHome(_ run: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try run(home)
    }
    private func write(_ text: String, _ relative: String, home: URL) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    func testDiscoversBothAgentsHistoriesMemoriesAndReferencedProjectWithoutFileSelection() throws {
        try withHome { home in
            try write("GlobalCodex SharedTerm", ".codex/AGENTS.md", home: home)
            try write("MemoryCodex", ".codex/memories/memory_summary.md", home: home)
            try write(#"{"session_id":"x","ts":1,"text":"HistoryCodex SharedTerm"}"#, ".codex/history.jsonl", home: home)
            let project = home.appendingPathComponent("work/example").path
            let session = try json(["type": "session_meta", "payload": ["cwd": project, "source": "vscode"]]) + "\n" + #"{"type":"event_msg","payload":{"type":"user_message","message":"SessionCodex"}}"#
            try write(session, ".codex/sessions/2026/10/14/test.jsonl", home: home)
            try write("ProjectTerm", "work/example/AGENTS.md", home: home)
            try write("NestedClaude", "work/example/.claude/CLAUDE.md", home: home)
            try write("GlobalClaude SharedTerm", ".claude/CLAUDE.md", home: home)
            try write(try json(["display": "HistoryClaude", "timestamp": 1, "project": project]), ".claude/history.jsonl", home: home)
            try write("MemoryClaude", ".claude/projects/-example/memory/MEMORY.md", home: home)
            try write(#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"SessionClaude SharedTerm"}]}}"#, ".claude/projects/-example/session.jsonl", home: home)
            let result = try AgentContextScanner.scan(home: home)
            let terms = Set(result.candidates.map(\.text))
            XCTAssertTrue(terms.isSuperset(of: ["GlobalCodex", "MemoryCodex", "HistoryCodex", "SessionCodex", "ProjectTerm", "NestedClaude", "GlobalClaude", "HistoryClaude", "MemoryClaude", "SessionClaude"]), "Found: \(terms)")
            XCTAssertEqual(result.sources, [.claude, .codex])
            XCTAssertEqual(result.unreadableFiles, 0)
            XCTAssertEqual(result.candidates.filter { $0.text == "SharedTerm" }.count, 1)
            XCTAssertEqual(result.candidates.first { $0.text == "SharedTerm" }?.sources, [.claude, .codex])
        }
    }

    func testSkipsUnrelatedFilesLinksToolRepliesAndSubagents() throws {
        try withHome { home in
            try write("AuthOnly", ".codex/auth.json", home: home)
            try write("SkillOnly", ".codex/memories/skills/helper/SKILL.md", home: home)
            try write("RandomFile", ".claude/projects/-example/notes.txt", home: home)
            try write(#"{"type":"user","message":{"role":"user","content":"SubagentClaude"}}"#, ".claude/projects/-example/session/subagents/agent.jsonl", home: home)
            let subagent = #"{"type":"session_meta","payload":{"source":{"subagent":{"other":"fixture"}}}}"# + "\n" + #"{"type":"event_msg","payload":{"type":"user_message","message":"SubagentCodex"}}"#
            try write(subagent, ".codex/sessions/sub.jsonl", home: home)
            let lines = [
                #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"SidechainOnly"}}"#,
                #"{"type":"user","isMeta":true,"message":{"role":"user","content":"MetaOnly"}}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ToolReply"},{"type":"text","text":"ToolWrapper"}]}}"#,
                #"{"type":"assistant","message":{"role":"assistant","content":"AssistantOnly"}}"#,
                ##"{"type":"user","message":{"role":"user","content":"# AGENTS.md instructions\nInjectedOnly"}}"##,
                #"{"type":"user","message":{"role":"user","content":"<environment_context>EnvironmentOnly</environment_context>"}}"#,
                #"{"type":"user","message":{"role":"user","content":"api_key=SecretValue\nSafeTerm"}}"#
            ].joined(separator: "\n")
            try write(lines, ".claude/projects/-example/session.jsonl", home: home)
            try write("LinkedOnly", "external.md", home: home)
            try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".codex/AGENTS.md"), withDestinationURL: home.appendingPathComponent("external.md"))
            let result = try AgentContextScanner.scan(home: home)
            XCTAssertEqual(result.candidates.map(\.text), ["SafeTerm"], "files=\(result.filesRead) unreadable=\(result.unreadableFiles)")
        }
    }

    func testMissingDirectoriesAndMalformedFilesAreNonfatal() throws {
        try withHome { home in
            let empty = try AgentContextScanner.scan(home: home)
            XCTAssertEqual(empty.filesRead, 0); XCTAssertEqual(empty.unreadableFiles, 0)
            try write("not-json\n{broken", ".codex/history.jsonl", home: home)
            try write("GoodTerm", ".claude/CLAUDE.md", home: home)
            try Data([0xFF, 0xFE]).write(to: home.appendingPathComponent(".codex/AGENTS.md"))
            let result = try AgentContextScanner.scan(home: home)
            XCTAssertEqual(result.candidates.map(\.text), ["GoodTerm"])
            XCTAssertEqual(result.unreadableFiles, 1)
        }
    }

    func testLargeHistoriesReadRecentCompleteMessagesWithinBudget() throws {
        try withHome { home in
            let first = #"{"session_id":"a","ts":1,"text":"OldTerm"}"#
            let padding = String(repeating: #"{"session_id":"a","ts":2,"text":"ordinary words 普通文字"}"# + "\n", count: 100)
            let last = #"{"session_id":"a","ts":3,"text":"RecentTerm"}"#
            try write(first + "\n" + padding + last + "\n", ".codex/history.jsonl", home: home)
            var limits = AgentContextScanner.Limits(); limits.bytesPerFile = 512; limits.bytesPerSource = 512
            let result = try AgentContextScanner.scan(home: home, limits: limits)
            XCTAssertTrue(result.limited)
            XCTAssertEqual(result.unreadableFiles, 0)
            XCTAssertEqual(Set(result.candidates.map(\.text)), ["OldTerm", "RecentTerm"])
        }
    }

    func testNewestSessionWinsFileBudgetAndBothSourcesGetBudget() throws {
        try withHome { home in
            for (name, text, date) in [("old", "OldTerm", Date(timeIntervalSince1970: 1)), ("new", "NewTerm", Date())] {
                let relative = ".codex/sessions/\(name).jsonl"
                try write(try json(["role": "user", "content": text]), relative, home: home)
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: home.appendingPathComponent(relative).path)
            }
            try write("ClaudeTerm", ".claude/CLAUDE.md", home: home)
            var limits = AgentContextScanner.Limits(); limits.filesPerSource = 1
            let result = try AgentContextScanner.scan(home: home, limits: limits)
            XCTAssertTrue(result.limited)
            XCTAssertEqual(Set(result.candidates.map(\.text)), ["NewTerm", "ClaudeTerm"])
        }
    }

    func testOversizedCodexMetadataCannotExposeSubagentTail() throws {
        try withHome { home in
            let header = try json(["type": "session_meta", "payload": ["source": ["subagent": "fixture"], "base_instructions": String(repeating: "x", count: 1_000)]])
            let tail = #"{"type":"event_msg","payload":{"type":"user_message","message":"SubagentOnly"}}"#
            try write(header + "\n" + tail, ".codex/sessions/large.jsonl", home: home)
            var limits = AgentContextScanner.Limits(); limits.bytesPerFile = 512
            let result = try AgentContextScanner.scan(home: home, limits: limits)
            XCTAssertTrue(result.candidates.isEmpty)
            XCTAssertTrue(result.limited)
            XCTAssertEqual(result.unreadableFiles, 1)
        }
    }


    func testExistingSpellingsExcludedBeforeCandidateLimit() throws {
        try withHome { home in
            try write("KnownTerm NewTerm", ".codex/AGENTS.md", home: home)
            let result = try AgentContextScanner.scan(home: home, excluding: [AppVocabulary.automaticTermKey("knownterm")])
            XCTAssertEqual(result.candidates.map(\.text), ["NewTerm"])
        }
    }

    func testProjectNamesFromMetadataAndManifestsRetainSourcesWithoutReadingOtherContent() throws {
        try withHome { home in
            let project = home.appendingPathComponent("work/moon-desk").path
            try write(try json(["type": "session_meta", "payload": ["cwd": project, "source": "vscode"]]), ".codex/sessions/main.jsonl", home: home)
            try write(try json(["display": "ordinary text", "timestamp": 1, "project": project]), ".claude/history.jsonl", home: home)
            try write(#"{"name":"@scope/MoonDesk","description":"SecretDescription","scripts":{"start":"InjectedCommand"}}"#, "work/moon-desk/package.json", home: home)
            try write("let package = Package(name: \"Moon-Desk\")", "work/moon-desk/Package.swift", home: home)
            try write("UnrelatedSecret", "work/moon-desk/.env", home: home)
            let result = try AgentContextScanner.scan(home: home)
            XCTAssertEqual(Set(result.candidates.map(\.text)), ["Moon-Desk", "MoonDesk"])
            XCTAssertTrue(result.candidates.allSatisfy { $0.isProject && $0.sources == [.claude, .codex] })
            let excluded = try AgentContextScanner.scan(home: home, excluding: [AppVocabulary.automaticTermKey("MOON-DESK")])
            XCTAssertEqual(excluded.candidates.map(\.text), ["MoonDesk"])
        }
    }

    func testProjectManifestFormatsUseOnlyLiteralDeclaredNames() {
        let fixtures = [
            ("Package.swift", "let package = Package(\n name: \"SwiftMoon\", products: [])", "SwiftMoon"),
            ("Cargo.toml", "[workspace]\nname = \"WrongName\"\n[package]\nname = 'rust-moon'\n[dependencies]\nname = \"WrongDependency\"", "rust-moon"),
            ("pyproject.toml", "[project] # package\nname = \"python-moon\"", "python-moon"),
            ("go.mod", "module github.com/example/go-moon/v2\n\ngo 1.24", "go-moon")
        ]
        for (filename, text, expected) in fixtures {
            XCTAssertEqual(ProjectVocabulary.declaredName(data: Data(text.utf8), filename: filename), expected)
        }
        for value in ["app", "src", "server", "../Secret", "https://secret.invalid", "Key=Secret", "line\nbreak"] {
            XCTAssertNil(ProjectVocabulary.name(value))
        }
        XCTAssertNil(ProjectVocabulary.declaredName(data: Data("{broken".utf8), filename: "package.json"))
        XCTAssertNil(ProjectVocabulary.declaredName(data: Data("let package = Package(name: computeName())".utf8), filename: "Package.swift"))
    }

    func testProjectNamesSurviveCandidateLimitAndSkipLinkedOrOversizedManifests() throws {
        try withHome { home in
            let project = home.appendingPathComponent("work/tiny-moon").path
            let terms = (0..<240).map { "CommonTerm\($0)" }.joined(separator: " ")
            try write(terms, ".codex/AGENTS.md", home: home)
            try write(try json(["type": "session_meta", "payload": ["cwd": project]]), ".codex/sessions/main.jsonl", home: home)
            try write(String(repeating: " ", count: 32_001) + #"{"name":"OversizedName"}"#, "work/tiny-moon/package.json", home: home)
            try write("[package]\nname = \"LinkedName\"", "external.toml", home: home)
            try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("work/tiny-moon/Cargo.toml"), withDestinationURL: home.appendingPathComponent("external.toml"))
            let result = try AgentContextScanner.scan(home: home)
            XCTAssertEqual(result.candidates.count, 200)
            XCTAssertEqual(result.candidates.first?.text, "tiny-moon")
            XCTAssertTrue(result.limited)
            XCTAssertFalse(result.candidates.contains { ["OversizedName", "LinkedName"].contains($0.text) })
        }
    }

    func testCancellationStopsScan() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AgentContextScanner.scan(home: URL(fileURLWithPath: "/nonexistent-fixture"))
        }
        do { _ = try await task.value; XCTFail("Cancelled scan returned results") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
