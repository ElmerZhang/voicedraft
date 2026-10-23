import Foundation
import os

/// Development diagnostics contain lifecycle metadata only: never audio, text, keys or URLs.
enum KeyboardDiagnostics {
    private static let lock = NSLock()
    private static let logger = Logger(subsystem: "com.voicedraft.ios", category: "KeyboardLifecycle")

    static func record(_ event: String, _ detail: String = "") {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        lock.lock()
        defer { lock.unlock() }
        let extensionProcess = Bundle.main.bundleIdentifier?.hasSuffix(".keyboard") == true
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) else { return }
        let url = directory.appendingPathComponent(extensionProcess ? "keyboard-diagnostics.json" : "app-diagnostics.json")
        var events = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        events.append(Entry(time: Date(), pid: ProcessInfo.processInfo.processIdentifier, event: event, detail: detail))
        if let data = try? JSONEncoder().encode(Array(events.suffix(200))) {
            try? data.write(to: url, options: .atomic)
        }
        logger.notice("\(event, privacy: .public) \(detail, privacy: .public)")
        #endif
    }

    static func error(_ error: Error) -> String {
        let error = error as NSError
        var result = "\(error.domain)(\(error.code)): \(error.localizedDescription)"
        if let reason = error.localizedFailureReason { result += " / \(reason)" }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== error {
            result += " / \(underlying.domain)(\(underlying.code)): \(underlying.localizedDescription)"
        }
        return result
    }

    private struct Entry: Codable {
        let time: Date
        let pid: Int32
        let event: String
        let detail: String
    }
}
