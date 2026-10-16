import Foundation

/// Token and duration counts a provider reported for one model call.
/// Parsed only from a response's usage object, so it never holds response text.
public struct ProviderUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public var cachedInputTokens: Int?
    public var audioTokens: Int?
    public var reportedAudioSeconds: Double?
    /// Every numeric field of the provider's usage object, flattened with dot keys
    /// (`prompt_tokens_details.audio_tokens`), so provider-specific counters survive.
    public var raw: [String: Double]

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil, cachedInputTokens: Int? = nil,
                audioTokens: Int? = nil, reportedAudioSeconds: Double? = nil, raw: [String: Double] = [:]) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens; self.audioTokens = audioTokens
        self.reportedAudioSeconds = reportedAudioSeconds; self.raw = raw
    }

    /// Sums two reports, for example the requests of a chunked long recording.
    public func adding(_ other: ProviderUsage) -> ProviderUsage {
        func sum<T: AdditiveArithmetic>(_ a: T?, _ b: T?) -> T? { a.map { $0 + (b ?? .zero) } ?? b }
        return ProviderUsage(inputTokens: sum(inputTokens, other.inputTokens), outputTokens: sum(outputTokens, other.outputTokens),
                             totalTokens: sum(totalTokens, other.totalTokens), cachedInputTokens: sum(cachedInputTokens, other.cachedInputTokens),
                             audioTokens: sum(audioTokens, other.audioTokens),
                             reportedAudioSeconds: sum(reportedAudioSeconds, other.reportedAudioSeconds),
                             raw: raw.merging(other.raw, uniquingKeysWith: +))
    }
}

// MARK: - Parsers (already-decoded JSON in, nil when the provider reported nothing)

extension ProviderUsage {
    static let maximumRawFields = 64

    /// OpenAI-compatible Chat Completions (also DashScope compatible mode and Qwen chat speech):
    /// a non-streaming body or the final `include_usage` stream chunk.
    public static func parse(chatCompletions root: [String: Any]) -> ProviderUsage? {
        normalized(root["usage"])
    }

    /// Anthropic `message_start` event (`message.usage`) or a non-streaming message body (`usage`).
    public static func parse(anthropicMessageStart root: [String: Any]) -> ProviderUsage? {
        normalized((root["message"] as? [String: Any])?["usage"] ?? root["usage"])
    }

    /// Anthropic `message_delta.usage` reports cumulative counts; present fields replace earlier ones.
    public static func merge(_ start: ProviderUsage?, anthropicMessageDelta root: [String: Any]) -> ProviderUsage? {
        guard let delta = root["usage"] as? [String: Any] else { return start }
        let raw = (start?.raw ?? [:]).merging(flatten(delta), uniquingKeysWith: { _, new in new })
        return normalized(raw: raw)
    }

    /// Responses API `response.completed` event (`response.usage`) or a non-streaming response body (`usage`).
    public static func parse(responsesCompleted root: [String: Any]) -> ProviderUsage? {
        normalized((root["response"] as? [String: Any])?["usage"] ?? root["usage"])
    }

    /// DashScope native multimodal generation (Qwen Audio HTTP): top-level `usage`.
    public static func parse(qwenAudio root: [String: Any]) -> ProviderUsage? {
        normalized(root["usage"])
    }

    /// DashScope Message ASR `task-finished` event: `payload.usage`, when the service sends one.
    public static func parse(messageASRTaskFinished root: [String: Any]) -> ProviderUsage? {
        normalized((root["payload"] as? [String: Any])?["usage"])
    }

    /// OpenAI transcription responses: `usage` with `type: duration, seconds` or `type: tokens`.
    public static func parse(whisper root: [String: Any]) -> ProviderUsage? {
        normalized(root["usage"])
    }

    /// Non-streaming writing body for any writing protocol.
    public static func parse(writing root: [String: Any], adapter: ModelAdapter) -> ProviderUsage? {
        switch adapter {
        case .anthropic: return parse(anthropicMessageStart: root)
        case .responses: return parse(responsesCompleted: root)
        default: return parse(chatCompletions: root)
        }
    }

    public static func parse(writing data: Data, adapter: ModelAdapter) -> ProviderUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parse(writing: root, adapter: adapter)
    }

    static func normalized(_ object: Any?) -> ProviderUsage? {
        guard let object = object as? [String: Any] else { return nil }
        return normalized(raw: flatten(object))
    }

    /// Maps the common provider spellings onto the named fields; `raw` keeps everything.
    static func normalized(raw: [String: Double]) -> ProviderUsage? {
        guard !raw.isEmpty else { return nil }
        func int(_ keys: String...) -> Int? { keys.lazy.compactMap { raw[$0] }.first.map { Int($0) } }
        let input = int("prompt_tokens", "input_tokens")
        let output = int("completion_tokens", "output_tokens")
        var total = int("total_tokens")
        if total == nil, let input, let output { total = input + output }
        return ProviderUsage(
            inputTokens: input, outputTokens: output, totalTokens: total,
            cachedInputTokens: int("prompt_tokens_details.cached_tokens", "input_tokens_details.cached_tokens", "cache_read_input_tokens"),
            audioTokens: int("prompt_tokens_details.audio_tokens", "input_tokens_details.audio_tokens", "input_token_details.audio_tokens"),
            reportedAudioSeconds: raw["seconds"] ?? raw["duration"] ?? raw["input_audio_seconds"],
            raw: raw)
    }

    /// Numeric leaves only (booleans and strings are skipped), nested objects and arrays
    /// joined with dots, bounded so an unexpected payload cannot grow a log line.
    static func flatten(_ object: [String: Any]) -> [String: Double] {
        var result: [String: Double] = [:]
        func visit(_ value: Any, _ path: String, depth: Int) {
            guard depth <= 4, result.count < maximumRawFields, path.utf8.count <= 128 else { return }
            if let number = value as? NSNumber {
                guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return }
                result[path] = number.doubleValue
            } else if let dictionary = value as? [String: Any] {
                for key in dictionary.keys.sorted() { visit(dictionary[key]!, path.isEmpty ? key : path + "." + key, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for (index, item) in array.prefix(16).enumerated() { visit(item, path + "." + String(index), depth: depth + 1) }
            }
        }
        visit(object, "", depth: 0)
        return result
    }
}

// MARK: - Log record

public enum ModelUsageKind: String, Codable, Sendable {
    case speech, writing, vocabularyFilter, learning, connectionTest
}

/// The exact call site. Raw values are a stable log contract; add new cases, never rename.
public enum ModelUsageSource: String, Codable, Sendable, CaseIterable {
    case dictationLiveSpeech = "dictation.liveSpeech"
    case dictationSpeech = "dictation.speech"
    case dictationWriting = "dictation.writing"
    case studioWriting = "studio.writing"
    case historyTranscribeAgain = "history.transcribeAgain"
    case historyRewrite = "history.rewrite"
    case styleApplyToSelection = "style.applyToSelection"
    case vocabularyLearning = "vocabulary.learning"
    case vocabularyAgentContextFilter = "vocabulary.agentContextFilter"
    case vocabularyScreenContextFilter = "vocabulary.screenContextFilter"
    case modelsConnectionTest = "models.connectionTest"
}

public enum ModelUsageOutcome: String, Codable, Sendable {
    case ok, failed
}

/// One line of the device-local model usage log. Counts, names, timings and outcomes only:
/// never transcript, result, selection or prompt text, credentials, or full URLs.
public struct ModelUsageRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var v: Int
    public var id: UUID
    public var date: Date
    public var kind: ModelUsageKind
    public var source: ModelUsageSource
    public var adapter: String
    public var model: String
    public var profileID: UUID
    public var profileName: String
    public var host: String
    public var mode: String?
    public var streamed: Bool
    public var audioSeconds: Double?
    public var latencyMs: Int
    public var outcome: ModelUsageOutcome
    public var failure: String?
    /// Failed calls only: a short, language-independent error description (`ModelUsageFailure.message`).
    public var failureMessage: String?
    public var takeID: UUID?
    public var usage: ProviderUsage?
    public var usageAvailable: Bool

    public init(id: UUID = UUID(), date: Date, kind: ModelUsageKind, source: ModelUsageSource, profile: ModelProfile, mode: WritingMode? = nil,
                streamed: Bool, audioSeconds: Double? = nil, latencyMs: Int, failure: Error? = nil,
                takeID: UUID? = nil, usage: ProviderUsage? = nil) {
        v = Self.schemaVersion; self.id = id; self.date = date; self.kind = kind; self.source = source
        adapter = profile.adapter.rawValue
        model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        profileID = profile.id; profileName = profile.name
        host = URLComponents(string: profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? ""
        self.mode = mode?.rawValue; self.streamed = streamed
        self.audioSeconds = audioSeconds.map { ($0 * 1000).rounded() / 1000 }
        self.latencyMs = max(0, latencyMs)
        outcome = failure == nil ? .ok : .failed
        self.failure = failure.map(ModelUsageFailure.category)
        failureMessage = failure.map(ModelUsageFailure.message)
        self.takeID = takeID; self.usage = usage; usageAvailable = usage != nil
    }
}

/// Short failure categories and descriptions; a provider's own error message is never logged.
public enum ModelUsageFailure {
    public static let maximumMessageLength = 300

    /// Which error a failed call hit, in English where the app controls the text, capped at 300
    /// characters: a `VoiceDraftError`'s message key (placeholders, never arguments), a
    /// `ProviderFailure`'s status, recognized code and request ID, a `FeatureError`'s message, a
    /// `URLError`'s code name and description, `noSpeech`, or else the error's type name.
    /// Never transcript text, audio, credentials or file paths.
    public static func message(_ error: Error) -> String {
        let message: String
        if let error = error as? VoiceDraftError, case .message(let text) = error {
            message = ProviderFailure.logDescription(text) ?? text.key
        } else if let error = error as? FeatureError {
            message = error.message
        } else if let error = error as? URLError {
            message = "\(urlCodeName(error.code)): \(error.localizedDescription)"
        } else if let error = error as? SpeechRecognitionError, case .noSpeech = error {
            message = "noSpeech"
        } else {
            message = String(describing: type(of: error))
        }
        return String(message.prefix(maximumMessageLength))
    }

    static func urlCodeName(_ code: URLError.Code) -> String {
        let names: [URLError.Code: String] = [
            .cancelled: "cancelled", .timedOut: "timedOut", .notConnectedToInternet: "notConnectedToInternet",
            .networkConnectionLost: "networkConnectionLost", .cannotFindHost: "cannotFindHost",
            .cannotConnectToHost: "cannotConnectToHost", .dnsLookupFailed: "dnsLookupFailed",
            .badServerResponse: "badServerResponse", .badURL: "badURL", .unsupportedURL: "unsupportedURL",
            .secureConnectionFailed: "secureConnectionFailed", .serverCertificateUntrusted: "serverCertificateUntrusted",
            .serverCertificateHasBadDate: "serverCertificateHasBadDate", .clientCertificateRejected: "clientCertificateRejected",
            .httpTooManyRedirects: "httpTooManyRedirects", .redirectToNonExistentLocation: "redirectToNonExistentLocation",
            .resourceUnavailable: "resourceUnavailable", .zeroByteResource: "zeroByteResource",
            .cannotDecodeContentData: "cannotDecodeContentData", .cannotParseResponse: "cannotParseResponse",
            .dataLengthExceedsMaximum: "dataLengthExceedsMaximum", .userAuthenticationRequired: "userAuthenticationRequired",
            .dataNotAllowed: "dataNotAllowed", .appTransportSecurityRequiresSecureConnection: "appTransportSecurityRequiresSecureConnection"
        ]
        return names[code] ?? "URLError(\(code.rawValue))"
    }
    public static func category(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return "cancelled"
            case .timedOut: return "timeout"
            default: return "network"
            }
        }
        if let status = httpStatus(error) { return "http:\(status)" }
        let message: String
        if let error = error as? VoiceDraftError, case .message(let text) = error { message = text.key }
        else if let error = error as? FeatureError { message = error.message }
        else { message = "" }
        return message.contains("timed out") ? "timeout" : "other"
    }

    /// The status carried by `ProviderFailure.http`.
    static func httpStatus(_ error: Error) -> Int? {
        guard let error = error as? VoiceDraftError, case .message(let text) = error,
              text.key.hasPrefix(ProviderFailure.httpKeyPrefix), let first = text.arguments.first,
              let status = Int(first), (100...599).contains(status) else { return nil }
        return status
    }
}

/// Collects one call's usage reports from a `@Sendable` sink; repeated reports are summed.
public final class ProviderUsageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProviderUsage?
    public init() {}
    public var usage: ProviderUsage? { lock.withLock { value } }
    public var sink: @Sendable (ProviderUsage) -> Void {
        { [self] usage in lock.withLock { value = value.map { $0.adding(usage) } ?? usage } }
    }
}
