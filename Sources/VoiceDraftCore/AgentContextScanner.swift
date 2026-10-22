import Foundation

public enum AgentContextSource: String, CaseIterable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
}

public struct AgentContextCandidate: Sendable {
    public let text: String
    public let sources: [AgentContextSource]
    public let isProject: Bool
    public init(text: String, sources: [AgentContextSource], isProject: Bool = false) {
        self.text = text; self.sources = sources; self.isProject = isProject
    }
}

public struct AgentContextScan: Sendable {
    public var candidates: [AgentContextCandidate] = []
    public var sources: [AgentContextSource] = []
    public var filesRead = 0
    public var unreadableFiles = 0
    public var limited = false
    public init() {}
}

/// On-demand, local discovery. Only known context locations are read; no model or shell is invoked.
public enum AgentContextScanner {
    struct Limits {
        var entriesPerSource = 12_000
        var filesPerSource = 80
        var bytesPerFile = 512_000
        var bytesPerSource = 8_000_000
        var projects = 12
    }
    private struct File {
        let url: URL
        let source: AgentContextSource
        let priority: Int
        let date: Date
    }

    /// The current user's home (the container home when sandboxed); available on macOS and iOS.
    public static var defaultHome: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

    public static func scan(home: URL = defaultHome, excluding: Set<String> = []) throws -> AgentContextScan {
        try scan(home: home, limits: Limits(), excluding: excluding)
    }

    static func scan(home: URL, limits: Limits, excluding: Set<String> = []) throws -> AgentContextScan {
        let fm = FileManager.default
        var report = AgentContextScan()
        var words: [String: (text: String, sources: Set<AgentContextSource>, count: Int, isProject: Bool)] = [:]
        var projects: [(URL, AgentContextSource)] = []
        var visited = Set<String>()

        func add(_ word: String, source: AgentContextSource, isProject: Bool = false, declaredSpelling: Bool = false) {
            let key = AppVocabulary.automaticTermKey(word)
            var value = words[key] ?? (word, [], 0, false)
            if declaredSpelling { value.text = word }
            value.sources.insert(source); value.count += 1
            value.isProject = value.isProject || isProject
            words[key] = value
        }

        func regular(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
        func file(_ url: URL, _ source: AgentContextSource, _ priority: Int) -> File? {
            guard regular(url) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return File(url: url, source: source, priority: priority, date: date)
        }
        func consume(_ item: File, budget: inout Int) throws {
            try Task.checkCancellation()
            guard budget > 0 else { report.limited = true; return }
            let identity = item.source.rawValue + ":" + item.url.standardizedFileURL.path
            guard visited.insert(identity).inserted else { return }
            do {
                let size = try item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let amount = min(limits.bytesPerFile, budget)
                if size > amount { report.limited = true }
                let handle = try FileHandle(forReadingFrom: item.url)
                defer { try? handle.close() }
                var data: Data
                if size > amount && item.url.pathExtension.lowercased() == "jsonl" {
                    // Keep session metadata and the newest complete messages. Never parse a partial line.
                    let head = try handle.read(upToCount: amount / 4) ?? Data()
                    data = head.lastIndex(of: 10).map { Data(head[...$0]) } ?? Data()
                    // Without a complete Codex header we cannot tell a main session from a subagent.
                    if data.isEmpty && item.source == .codex && item.url.lastPathComponent != "history.jsonl" {
                        budget -= head.count; report.unreadableFiles += 1; return
                    }
                    try handle.seek(toOffset: UInt64(size - (amount - head.count)))
                    let tail = try handle.read(upToCount: amount - head.count) ?? Data()
                    if let boundary = tail.firstIndex(of: 10) { data.append(tail.suffix(from: tail.index(after: boundary))) }
                } else {
                    data = try handle.read(upToCount: amount) ?? Data()
                    if size > amount, let boundary = data.lastIndex(of: 10) {
                        data = Data(data[...boundary])
                    }
                }
                budget -= min(size, amount)
                let document = try ContextVocabulary.document(data: data, filename: item.url.lastPathComponent)
                report.filesRead += 1
                if !report.sources.contains(item.source) { report.sources.append(item.source) }
                for path in document.projects where projects.count < limits.projects {
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    if path.hasPrefix("/"), !projects.contains(where: { $0.0 == url && $0.1 == item.source }) {
                        projects.append((url, item.source))
                    }
                }
                for word in try ContextVocabulary.terms(in: document.text) {
                    add(word, source: item.source)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { report.unreadableFiles += 1 }
        }

        for source in AgentContextSource.allCases {
            try Task.checkCancellation()
            let root = home.appendingPathComponent(source == .codex ? ".codex" : ".claude")
            // Do not follow context-directory symlinks into unrelated trees.
            guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.standardizedFileURL.path else { continue }
            var files: [File] = []
            for name in [source == .codex ? "AGENTS.md" : "CLAUDE.md", "history.jsonl"] {
                if let item = file(root.appendingPathComponent(name), source, 0) { files.append(item) }
            }
            let directories = source == .codex ? ["memories", "sessions", "archived_sessions"] : ["projects"]
            var inspected = 0
            for directory in directories {
                let base = root.appendingPathComponent(directory)
                guard (try? base.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                guard base.resolvingSymlinksInPath().standardizedFileURL.path == base.standardizedFileURL.path else { continue }
                guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in report.unreadableFiles += 1; return true }) else { continue }
                while let url = enumerator.nextObject() as? URL {
                    try Task.checkCancellation()
                    inspected += 1
                    if inspected > limits.entriesPerSource { report.limited = true; break }
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    // DirectoryEnumerator may canonicalize /var to /private/var in returned URLs.
                    let relative = Array(url.pathComponents.suffix(enumerator.level))
                    if values?.isSymbolicLink == true || relative.contains("subagents") || relative.contains("skills") || relative.count > 5 {
                        enumerator.skipDescendants(); continue
                    }
                    guard values?.isDirectory != true else { continue }
                    let isMemory = url.pathExtension.lowercased() == "md" && (directory == "memories" || relative.dropLast().contains("memory"))
                    let isSession = url.pathExtension.lowercased() == "jsonl" && directory != "memories" && (source == .codex || relative.count == 2)
                    if isMemory || isSession, let item = file(url, source, isMemory ? 1 : 2) { files.append(item) }
                }
                if inspected > limits.entriesPerSource { break }
            }
            // Reserve room for recent conversations even when an agent has a large memory archive.
            files.sort { $0.priority == $1.priority ? ($0.date == $1.date ? $0.url.path < $1.url.path : $0.date > $1.date) : $0.priority < $1.priority }
            var memoryCount = 0
            files = files.filter { item in
                guard item.priority == 1 else { return true }
                memoryCount += 1
                if memoryCount > 12 { report.limited = true; return false }
                return true
            }
            if files.count > limits.filesPerSource { report.limited = true }
            var budget = limits.bytesPerSource
            for item in files.prefix(limits.filesPerSource) { try consume(item, budget: &budget) }
        }
        // Project paths come from session metadata/history, never from instructions in the text.
        // Read only exact conventional files, not the rest of a workspace or its parent directories.
        let referencedProjects = projects
        for (project, source) in referencedProjects {
            try Task.checkCancellation()
            guard project != home.standardizedFileURL,
                  (try? project.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  project.resolvingSymlinksInPath().standardizedFileURL.path == project.path else { continue }
            var budget = min(limits.bytesPerFile, 128_000)
            if let name = ProjectVocabulary.name(project.lastPathComponent) { add(name, source: source, isProject: true) }
            for name in ProjectVocabulary.manifests {
                try Task.checkCancellation()
                let url = project.appendingPathComponent(name)
                guard regular(url), url.resolvingSymlinksInPath().path == url.path else { continue }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= min(32_000, budget) else { report.limited = true; continue }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: min(32_000, budget)) ?? Data()
                    budget -= data.count; report.filesRead += 1
                    if let term = ProjectVocabulary.declaredName(data: data, filename: name) { add(term, source: source, isProject: true, declaredSpelling: true) }
                } catch { report.unreadableFiles += 1 }
            }
            for name in ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md"] {
                let url = project.appendingPathComponent(name)
                guard url.resolvingSymlinksInPath().path == url.path else { continue }
                if let item = file(url, source, 0) { try consume(item, budget: &budget) }
            }
        }
        report.sources.sort { $0.rawValue < $1.rawValue }
        report.candidates = words.filter { !excluding.contains($0.key) }.values.sorted {
            if $0.isProject != $1.isProject { return $0.isProject }
            return $0.count == $1.count ? $0.text < $1.text : $0.count > $1.count
        }.prefix(200).map {
            AgentContextCandidate(text: $0.text, sources: $0.sources.sorted { $0.rawValue < $1.rawValue }, isProject: $0.isProject)
        }
        return report
    }
}
