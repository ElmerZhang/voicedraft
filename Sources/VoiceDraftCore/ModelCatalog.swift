import Foundation

public enum ModelAdapter: String, Codable {
    case qwenChatSpeech, qwenAudioHTTP, qwenMessageWebSocket, qwenChatWriting, unconfigured

    public var title: String {
        switch self {
        case .qwenChatSpeech, .qwenChatWriting: return "HTTP · Chat Completions"
        case .qwenAudioHTTP: return "HTTP · Qwen Audio"
        case .qwenMessageWebSocket: return "WebSocket · Qwen ASR Message"
        case .unconfigured: return "Choose a supported model"
        }
    }
    public var path: String {
        switch self {
        case .qwenMessageWebSocket: return "/api-ws/v1/inference"
        case .qwenAudioHTTP: return "/api/v1/services/aigc/multimodal-generation/generation"
        default: return "/compatible-mode/v1/chat/completions"
        }
    }
    public var isWebSocket: Bool { self == .qwenMessageWebSocket }
}

public enum VocabularyCapability { case none, context, weighted }

public struct CatalogModel: Identifiable {
    public let id: String
    public let role: ModelRole
    public let adapter: ModelAdapter
    public let vocabulary: VocabularyCapability
}

public enum ModelCatalog {
    // Only entries with implemented, fixture-tested adapters belong in this list.
    public static let models: [CatalogModel] = [
        .init(id: "qwen-audio-3.1-asr-flash-message", role: .speech, adapter: .qwenMessageWebSocket, vocabulary: .weighted),
        .init(id: "qwen-audio-3.1-asr-flash", role: .speech, adapter: .qwenAudioHTTP, vocabulary: .weighted),
        .init(id: "qwen-audio-3.0-asr-flash", role: .speech, adapter: .qwenAudioHTTP, vocabulary: .weighted),
        .init(id: "qwen3-asr-flash", role: .speech, adapter: .qwenChatSpeech, vocabulary: .context),
        .init(id: "qwen3.7-flash", role: .writing, adapter: .qwenChatWriting, vocabulary: .none),
        .init(id: "qwen-plus", role: .writing, adapter: .qwenChatWriting, vocabulary: .none),
        .init(id: "qwen-flash", role: .writing, adapter: .qwenChatWriting, vocabulary: .none)
    ]
    public static func models(for role: ModelRole) -> [CatalogModel] { models.filter { $0.role == role } }
    public static func find(_ model: String, role: ModelRole) -> CatalogModel? {
        models.first { $0.id == model.trimmingCharacters(in: .whitespacesAndNewlines) && $0.role == role }
    }
    public static func adapter(for model: String, role: ModelRole) -> ModelAdapter {
        find(model, role: role)?.adapter ?? (role == .writing ? .qwenChatWriting : .unconfigured)
    }

    /// Retains the user's origin (region/workspace/port); never guesses a different account or host.
    public static func endpoint(_ current: String, for adapter: ModelAdapter) -> String {
        guard adapter != .unconfigured,
              var parts = URLComponents(string: current.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.host != nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["https", "wss", "http", "ws"].contains(parts.scheme ?? "") else { return current }
        let local = ["localhost", "127.0.0.1", "[::1]"].contains(parts.host ?? "")
        let insecure = local && ["http", "ws"].contains(parts.scheme ?? "")
        parts.scheme = adapter.isWebSocket ? (insecure ? "ws" : "wss") : (insecure ? "http" : "https")
        parts.path = adapter.path
        return parts.string ?? current
    }
}

public struct WeightedHotword: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var text: String
    public var weight: Int
    public init(text: String = "", weight: Int = 3) { self.text = text; self.weight = weight }
}

public struct SpeechOptions: Codable, Equatable {
    public var useVocabulary = true
    public var defaultWeight = 3
    public var hotwords: [WeightedHotword] = []
    public init() {}

    public func validate() throws {
        guard (1...5).contains(defaultWeight), hotwords.count <= 2000,
              Set(hotwords.map(\.id)).count == hotwords.count,
              hotwords.allSatisfy({ (1...5).contains($0.weight) || $0.weight == 50 }),
              hotwords.filter({ $0.weight == 50 }).count <= 50,
              hotwords.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.count <= 100 && !$0.text.contains(where: \.isNewline) }) else {
            throw VoiceDraftError.message("Use nonempty single-line hotwords (up to 100 characters), weights 1–5 or 50, and at most 50 super hotwords.")
        }
        let words = hotwords.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Set(words).count == words.count else { throw VoiceDraftError.message("Remove duplicate custom hotwords.") }
    }

    public func weightedVocabulary(_ personalWords: String) throws -> [String: Int] {
        try validate()
        guard useVocabulary else { return [:] }
        var result: [String: Int] = [:]
        for word in personalWords.split(whereSeparator: \.isNewline) {
            let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty { result[term] = defaultWeight }
        }
        for word in hotwords { result[word.text.trimmingCharacters(in: .whitespacesAndNewlines)] = word.weight }
        guard result.count <= 2000, result.keys.allSatisfy({ $0.count <= 100 }) else {
            throw VoiceDraftError.message("This model accepts up to 2,000 hotwords. Keep each word or phrase within 100 characters.")
        }
        return result
    }
}

extension ModelProfile {
    public var catalogModel: CatalogModel? { ModelCatalog.find(model, role: role) }
    public var vocabularyCapability: VocabularyCapability { catalogModel?.vocabulary ?? .none }

    public mutating func selectModel(_ id: String) {
        guard model != id else { return }
        let next = ModelCatalog.adapter(for: id, role: role)
        if adapter != next {
            endpoint = ModelCatalog.endpoint(endpoint, for: next)
            extraJSON = role == .writing ? "{\"enable_thinking\": false}" : "{}"
        }
        model = id; adapter = next
        speechOptions = SpeechOptions()
    }

    public func validateForInference() throws {
        let profile = normalizedInput
        guard profile.adapter != .unconfigured,
              profile.adapter == ModelCatalog.adapter(for: profile.model, role: profile.role),
              !profile.model.isEmpty else {
            throw VoiceDraftError.message("Choose a supported model for \(name) in Models. This model has no matching adapter.")
        }
        _ = try Endpoint.validate(profile.endpoint, webSocket: adapter.isWebSocket)
        if let url = URL(string: profile.endpoint), let host = url.host,
           host == "dashscope.aliyuncs.com" || host == "dashscope-intl.aliyuncs.com" || host.hasSuffix(".maas.aliyuncs.com") {
            guard url.path == adapter.path else {
                throw VoiceDraftError.message("\(model) requires \(adapter.title) at \(adapter.path). Use the model endpoint in Models.")
            }
        }
        _ = try modelParameters()
        try speechOptions.validate()
    }

    public func modelParameters() throws -> [String: Any] {
        let parameters = try QwenRequests.extras(extraJSON)
        let allowed: Set<String>
        switch adapter {
        case .qwenChatWriting, .unconfigured: return parameters
        case .qwenChatSpeech: allowed = ["asr_options"]
        case .qwenAudioHTTP:
            allowed = model == "qwen-audio-3.1-asr-flash"
                ? ["language_hints", "keep_dialect", "speaker_diarization_enabled", "vocabulary_id"]
                : ["language_hints", "vocabulary_id"]
        case .qwenMessageWebSocket:
            allowed = ["language_hints", "disfluency_removal_enabled", "keep_dialect", "vad_model", "max_sentence_silence", "heartbeat", "speech_noise_threshold", "vocabulary_id"]
        }
        guard Set(parameters.keys).isSubset(of: allowed) else {
            throw VoiceDraftError.message("Advanced parameters do not match this model. Supported keys: \(allowed.sorted().joined(separator: ", ")). Configure hotwords in the vocabulary controls.")
        }
        return parameters
    }
}
