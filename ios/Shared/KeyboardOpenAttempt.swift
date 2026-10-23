import Foundation

/// How the keyboard tries to open the containing app, in the order it tries them. See `docs/ios.md`, flow 3.
enum KeyboardOpenStrategy: String, Codable, CaseIterable {
    /// `NSExtensionContext.open(_:completionHandler:)`.
    case extensionContext = "ext"
    /// The `UIApplication` instance reached by walking the input view controller's responder chain.
    case responderChain = "chain"
    /// `UIApplication.sharedApplication` looked up by name at run time.
    case sharedApplication = "app"

    /// The 1-based number shown in the keyboard's status line ("method N").
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

/// The scheme spelling used for one try. The registered scheme is `voicedraft`; `VoiceDraft` is a retry only.
enum KeyboardOpenURLForm: String, Codable {
    case lowercase
    case uppercase
}

/// What one try returned.
enum KeyboardOpenResult: String, Codable {
    case success = "true"
    case failure = "false"
    /// The strategy had nothing to call: no extension context, or no responder or class that answers the selector.
    case unavailable = "none"
}

/// One try to open the containing app, kept in `open-attempts.json` for diagnosis. Holds no other data.
struct KeyboardOpenAttempt: Codable, Equatable {
    var strategy: KeyboardOpenStrategy
    var urlForm: KeyboardOpenURLForm
    var result: KeyboardOpenResult
    var at: Date
}

/// Runs the open strategies in order and stops at the first success. Pure apart from the injected `attempt`,
/// so the sequencing is unit-tested with simulated results.
enum KeyboardOpenSequence {
    struct Outcome: Equatable {
        var attempts: [KeyboardOpenAttempt]
        /// The strategy that opened the app, or nil when every try failed.
        var succeeded: KeyboardOpenStrategy? {
            attempts.last(where: { $0.result == .success })?.strategy
        }
    }

    /// Performs one try and reports its result exactly once.
    typealias Attempt = (KeyboardOpenStrategy, KeyboardOpenURLForm, @escaping (KeyboardOpenResult) -> Void) -> Void

    /// Tries each strategy with the lower-case scheme, and again with the upper-case scheme only when the
    /// lower-case form returned `.failure`. Later strategies are not tried after a success.
    static func run(strategies: [KeyboardOpenStrategy] = KeyboardOpenStrategy.allCases,
                    now: @escaping () -> Date = Date.init,
                    attempt: @escaping Attempt,
                    completion: @escaping (Outcome) -> Void) {
        var steps: [(KeyboardOpenStrategy, KeyboardOpenURLForm)] = []
        for strategy in strategies {
            steps.append((strategy, .lowercase))
            steps.append((strategy, .uppercase))
        }
        var attempts: [KeyboardOpenAttempt] = []

        func next(_ index: Int) {
            guard index < steps.count else {
                completion(Outcome(attempts: attempts))
                return
            }
            let (strategy, form) = steps[index]
            if form == .uppercase {
                // Retry only after the same strategy's lower-case form reported a failure.
                guard attempts.last?.strategy == strategy, attempts.last?.result == .failure else {
                    next(index + 1)
                    return
                }
            }
            var reported = false
            attempt(strategy, form) { result in
                guard !reported else { return }
                reported = true
                attempts.append(KeyboardOpenAttempt(strategy: strategy, urlForm: form, result: result, at: now()))
                if result == .success {
                    completion(Outcome(attempts: attempts))
                } else {
                    next(index + 1)
                }
            }
        }
        next(0)
    }

    /// `ext=false · chain=none · app=false`. A strategy retried with the upper-case scheme shows both results,
    /// lower-case first: `ext=false/false`.
    static func summary(_ attempts: [KeyboardOpenAttempt]) -> String {
        KeyboardOpenStrategy.allCases.compactMap { strategy -> String? in
            let results = attempts.filter { $0.strategy == strategy }.map(\.result.rawValue)
            guard !results.isEmpty else { return nil }
            return "\(strategy.rawValue)=\(results.joined(separator: "/"))"
        }.joined(separator: " · ")
    }
}

/// Finds the first object in a `next`-linked chain (the responder chain) that satisfies `predicate`. Pure, so the
/// filter is tested with stub chains. Stops after `limit` steps in case a chain loops.
enum ResponderChainSearch {
    static func first<Node: AnyObject>(from start: Node?, limit: Int = 64, next: (Node) -> Node?,
                                       where predicate: (Node) -> Bool) -> Node? {
        var node = start
        var steps = 0
        while let current = node, steps < limit {
            if predicate(current) { return current }
            node = next(current)
            steps += 1
        }
        return nil
    }
}

extension KeyboardRecordLink {
    /// The same link with the scheme spelled `VoiceDraft`, for the upper-case retry.
    static func uppercasedScheme(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "VoiceDraft"
        return components.url
    }
}

/// Stores the latest keyboard open tries as `open-attempts.json` in the app-group container, newest last.
struct KeyboardOpenAttemptStore {
    static let fileName = "open-attempts.json"
    static let limit = 20

    private let fileURL: URL?

    init(fileManager: FileManager = .default) {
        fileURL = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// Creates a store backed by an explicit file, for previews and tests.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Appends `attempts` and keeps the newest `limit` records.
    func append(_ attempts: [KeyboardOpenAttempt]) throws {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        let kept = Array((read() + attempts).suffix(Self.limit))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(kept).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func read() -> [KeyboardOpenAttempt] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([KeyboardOpenAttempt].self, from: data)) ?? []
    }
}
