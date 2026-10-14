import AppKit

struct InsertionClipboardSnapshot {
    let generation: Int
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(_ board: NSPasteboard, maximumBytes: Int) -> Self? {
        let generation = board.changeCount
        var remaining = maximumBytes
        guard remaining >= 0 else { return nil }
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in board.pasteboardItems ?? [] {
            var formats: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type), data.count <= remaining else { return nil }
                remaining -= data.count; formats[type] = data
            }
            items.append(formats)
        }
        guard board.changeCount == generation else { return nil }
        return Self(generation: generation, items: items)
    }

    @MainActor
    func restore(_ board: NSPasteboard, ifGeneration generation: Int) {
        guard board.changeCount == generation else { return }
        board.clearContents()
        let restored = items.map { formats in
            let item = NSPasteboardItem()
            for (type, data) in formats { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }
}

/// A timed-out lazy clipboard provider may keep its thread. Do not enqueue more
/// reads behind it or spawn more workers; subsequent attempts fail until it exits.
final class InsertionClipboardReader: @unchecked Sendable {
    static let shared = InsertionClipboardReader()
    private let queue = DispatchQueue(label: "com.voicedraft.clipboard-snapshot", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false

    func read(name: NSPasteboard.Name, timeout: TimeInterval = 0.25,
              maximumBytes: Int = 8 * 1_024 * 1_024) async -> InsertionClipboardSnapshot? {
        await read(timeout: timeout) {
            InsertionClipboardSnapshot.capture(NSPasteboard(name: name), maximumBytes: maximumBytes)
        }
    }

    func read(timeout: TimeInterval, operation: @escaping @Sendable () -> InsertionClipboardSnapshot?) async -> InsertionClipboardSnapshot? {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !busy else { lock.unlock(); continuation.resume(returning: nil); return }
            busy = true; lock.unlock()
            let completion = Completion(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { completion.finish(nil) }
            queue.async { [self] in
                let snapshot = operation()
                lock.lock(); busy = false; lock.unlock()
                completion.finish(snapshot)
            }
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<InsertionClipboardSnapshot?, Never>?
        init(_ continuation: CheckedContinuation<InsertionClipboardSnapshot?, Never>) { self.continuation = continuation }
        func finish(_ snapshot: InsertionClipboardSnapshot?) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: snapshot)
        }
    }
}
