import Foundation

public enum ModelAdapter: String, Codable, CaseIterable {
    case whisper, doubao, googleSpeech, chatCompletions, anthropic, responses
    case qwenChatSpeech, qwenAudioHTTP, qwenMessageWebSocket, qwenChatWriting, unconfigured

    public var title: String {
        switch self {
        case .qwenChatSpeech, .qwenChatWriting: return L("HTTP · Chat Completions")
        case .qwenAudioHTTP: return L("HTTP · Qwen Audio")
        case .qwenMessageWebSocket: return L("WebSocket · Qwen ASR Message")
        case .whisper: return "Whisper compatible · HTTP"
        case .doubao: return "Doubao · WebSocket"
        case .googleSpeech: return "Google Speech v2 · HTTP"
        case .chatCompletions: return "Chat Completions"
        case .anthropic: return "Anthropic Messages"
        case .responses: return "Responses"
        case .unconfigured: return L("Choose a supported model")
        }
    }
    public var path: String {
        switch self {
        case .qwenMessageWebSocket: return "/api-ws/v1/inference"
        case .qwenAudioHTTP: return "/api/v1/services/aigc/multimodal-generation/generation"
        case .whisper: return "/v1/audio/transcriptions"
        case .doubao: return "/api/v3/sauc/bigmodel"
        case .googleSpeech: return "/v2/projects/PROJECT/locations/global/recognizers/_:recognize"
        case .chatCompletions: return "/v1/chat/completions"
        case .anthropic: return "/v1/messages"
        case .responses: return "/v1/responses"
        default: return "/compatible-mode/v1/chat/completions"
        }
    }
    public var isWebSocket: Bool { self == .qwenMessageWebSocket || self == .doubao }
    public var isWriting: Bool { [.qwenChatWriting, .chatCompletions, .anthropic, .responses].contains(self) }
    public var isGeneric: Bool { [.whisper, .doubao, .googleSpeech, .chatCompletions, .anthropic, .responses].contains(self) }
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

// Decode-only schema-v2 vocabulary. Profiles never encode or use these at runtime.
struct LegacyWeightedHotword: Decodable, Equatable {
    public var id = UUID()
    public var text: String
    public var weight: Int
    public init(text: String = "", weight: Int = 3) { self.text = text; self.weight = weight }
}

struct LegacySpeechOptions: Decodable, Equatable {
    public var useVocabulary = true
    public var defaultWeight = 3
    public var hotwords: [LegacyWeightedHotword] = []
    public init() {}
}

extension ModelProfile {
    public var catalogModel: CatalogModel? { ModelCatalog.find(model, role: role) }
    public var vocabularyCapability: VocabularyCapability { adapter == .whisper || adapter == .doubao || adapter == .googleSpeech ? .context : (catalogModel?.vocabulary ?? .none) }

    public mutating func selectModel(_ id: String) {
        guard model != id else { return }
        let next = ModelCatalog.adapter(for: id, role: role)
        if adapter != next {
            endpoint = ModelCatalog.endpoint(endpoint, for: next)
            extraJSON = role == .writing ? "{\"enable_thinking\": false}" : "{}"
        }
        model = id; adapter = next
    }

    public func validateForInference() throws {
        let profile = normalizedInput
        guard profile.adapter != .unconfigured,
              (profile.adapter.isGeneric ? (profile.adapter.isWriting == (profile.role == .writing)) : profile.adapter == ModelCatalog.adapter(for: profile.model, role: profile.role)),
              !profile.model.isEmpty else {
            throw VoiceDraftError.message("Choose a supported model for \(name) in Models. This model has no matching adapter.")
        }
        _ = try Endpoint.validate(profile.endpoint, webSocket: adapter.isWebSocket)
        if !adapter.isGeneric, let url = URL(string: profile.endpoint), let host = url.host,
           host == "dashscope.aliyuncs.com" || host == "dashscope-intl.aliyuncs.com" || host.hasSuffix(".maas.aliyuncs.com") {
            guard url.path == adapter.path else {
                throw VoiceDraftError.message("\(model) requires \(adapter.title) at \(adapter.path). Use the model endpoint in Models.")
            }
        }
        _ = try modelParameters()
    }

    public func modelParameters() throws -> [String: Any] {
        let parameters = try QwenRequests.extras(extraJSON)
        let allowed: Set<String>
        switch adapter {
        case .qwenChatWriting, .unconfigured, .chatCompletions, .anthropic, .responses, .whisper, .googleSpeech, .doubao: return parameters
        case .qwenChatSpeech: allowed = ["asr_options"]
        case .qwenAudioHTTP:
            allowed = model == "qwen-audio-3.1-asr-flash"
                ? ["language_hints", "keep_dialect", "speaker_diarization_enabled"]
                : ["language_hints"]
        case .qwenMessageWebSocket:
            allowed = ["language_hints", "disfluency_removal_enabled", "keep_dialect", "vad_model", "max_sentence_silence", "heartbeat", "speech_noise_threshold"]
        }
        guard Set(parameters.keys).isSubset(of: allowed) else {
            throw VoiceDraftError.message("Advanced parameters do not match this model. Supported keys: \(allowed.sorted().joined(separator: ", ")). Manage hotwords in the app vocabulary.")
        }
        return parameters
    }
}
