import Foundation

public enum VoiceDraftError: LocalizedError {
    case message(LocalizedMessage)
    public var errorDescription: String? {
        switch self { case .message(let text): return L(text) }
    }
}

public enum ModelRole: String, Codable, CaseIterable, Identifiable {
    case speech, writing
    public var id: String { rawValue }
    public var title: String { self == .speech ? L("Speech recognition") : L("Writing model") }
}

public struct ModelProfile: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var role: ModelRole
    public var endpoint: String
    public var model: String
    public var extraJSON: String
    public var adapter: ModelAdapter
    var legacySpeechOptions: LegacySpeechOptions?

    public init(id: UUID = UUID(), name: String, role: ModelRole, endpoint: String, model: String, extraJSON: String = "{}", adapter: ModelAdapter? = nil) {
        self.id = id; self.name = name; self.role = role
        self.endpoint = endpoint; self.model = model; self.extraJSON = extraJSON
        self.adapter = adapter ?? ModelCatalog.adapter(for: model, role: role)
    }

    private enum CodingKeys: String, CodingKey { case id, name, role, endpoint, model, extraJSON, adapter, speechOptions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        role = try c.decode(ModelRole.self, forKey: .role)
        endpoint = try c.decode(String.self, forKey: .endpoint)
        model = try c.decode(String.self, forKey: .model).trimmingCharacters(in: .whitespacesAndNewlines)
        extraJSON = try c.decode(String.self, forKey: .extraJSON)
        legacySpeechOptions = try c.decodeIfPresent(LegacySpeechOptions.self, forKey: .speechOptions)
        if let saved = try c.decodeIfPresent(ModelAdapter.self, forKey: .adapter) {
            adapter = saved
        } else {
            adapter = ModelCatalog.adapter(for: model, role: role)
            // v1 allowed arbitrary ASR IDs but always sent chat HTTP. Repair known mismatches,
            // retaining the origin, UUID, key association, and advanced parameters.
            let oldPaths = [ModelAdapter.qwenChatSpeech.path, ModelAdapter.qwenAudioHTTP.path, ModelAdapter.qwenMessageWebSocket.path]
            if adapter != .unconfigured, let url = URL(string: endpoint), oldPaths.contains(url.path) {
                endpoint = ModelCatalog.endpoint(endpoint, for: adapter)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(role, forKey: .role); try c.encode(endpoint, forKey: .endpoint)
        try c.encode(model, forKey: .model); try c.encode(extraJSON, forKey: .extraJSON)
        try c.encode(adapter, forKey: .adapter)
    }

    public static func qwen(_ role: ModelRole) -> ModelProfile {
        ModelProfile(name: role == .speech ? "Qwen ASR" : "Qwen Writing", role: role,
                     endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
                     model: role == .speech ? "qwen3-asr-flash" : "qwen-plus",
                     extraJSON: role == .speech ? "{}" : "{\"enable_thinking\": false}")
    }

    public var normalizedInput: ModelProfile {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

public enum WritingMode: String, Codable, CaseIterable, Identifiable {
    case verbatim, polish, translate, edit, ask
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .verbatim: return L("Transcribe")
        case .polish: return L("Polish")
        case .translate: return L("Translate")
        case .edit: return L("Edit selection")
        case .ask: return L("Ask")
        }
    }
    public var icon: String {
        switch self {
        case .verbatim: return "text.quote"
        case .polish: return "sparkles"
        case .translate: return "character.bubble"
        case .edit: return "pencil.line"
        case .ask: return "bubble.left.and.bubble.right"
        }
    }
}

public struct SharedSettings: Codable, Equatable {
    public var schemaVersion = 3
    public var profiles: [ModelProfile]
    public var speechID: UUID
    public var writingID: UUID
    public var vocabulary = AppVocabulary()
    public var stylePrompt = "Preserve my tone and meaning. Be concise. Keep technical terms and mixed languages intact."
    public var targetLanguage = "English"

    public init() {
        let speech = ModelProfile.qwen(.speech), writing = ModelProfile.qwen(.writing)
        profiles = [speech, writing]; speechID = speech.id; writingID = writing.id
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, profiles, speechID, writingID, hotwords, vocabulary, stylePrompt, targetLanguage }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard (1...3).contains(version) else { throw VoiceDraftError.message("This configuration needs a newer app.") }
        schemaVersion = 3
        profiles = try c.decode([ModelProfile].self, forKey: .profiles)
        speechID = try c.decode(UUID.self, forKey: .speechID)
        writingID = try c.decode(UUID.self, forKey: .writingID)
        if version < 3 {
            vocabulary = AppVocabulary.migrate(words: try c.decodeIfPresent(String.self, forKey: .hotwords) ?? "", profiles: &profiles, activeID: speechID)
        } else {
            vocabulary = try c.decode(AppVocabulary.self, forKey: .vocabulary)
            for i in profiles.indices { profiles[i].legacySpeechOptions = nil }
        }
        stylePrompt = try c.decode(String.self, forKey: .stylePrompt)
        targetLanguage = try c.decode(String.self, forKey: .targetLanguage)
    }

    public var speech: ModelProfile? { profiles.first { $0.id == speechID && $0.role == .speech } }
    public var writing: ModelProfile? { profiles.first { $0.id == writingID && $0.role == .writing } }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(speechID, forKey: .speechID); try c.encode(writingID, forKey: .writingID)
        try c.encode(vocabulary, forKey: .vocabulary)
        try c.encode(stylePrompt, forKey: .stylePrompt); try c.encode(targetLanguage, forKey: .targetLanguage)
    }

    public func validate() throws {
        guard schemaVersion == 3 else { throw VoiceDraftError.message("This configuration needs a newer app.") }
        guard !profiles.isEmpty, profiles.count <= 50,
              Set(profiles.map(\.id)).count == profiles.count,
              speech != nil, writing != nil else {
            throw VoiceDraftError.message("Select a valid speech profile and writing profile.")
        }
        try vocabulary.validate()
        guard stylePrompt.utf8.count <= 20_000,
              !targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceDraftError.message("Check the dictionary, style prompt, and target language.")
        }
        for p in profiles {
            // Keep legacy/custom addresses editable even when they need protocol repair.
            // Inference performs the stricter adapter/scheme/path validation before reading audio.
            let scheme = URL(string: p.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme
            _ = try Endpoint.validate(p.endpoint, webSocket: scheme == "wss" || scheme == "ws")
            guard !p.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceDraftError.message("Every profile needs a name and model ID.")
            }
            _ = try QwenRequests.extras(p.extraJSON)
        }
    }
}

public struct HistoryEntry: Codable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var mode: WritingMode
    public var original: String
    public var result: String
    public var application: String
    public var duration: Double
    public init(mode: WritingMode, original: String, result: String, application: String, duration: Double) {
        self.mode = mode; self.original = original; self.result = result
        self.application = application; self.duration = duration
    }
}

public enum Endpoint {
    public static func validate(_ value: String, webSocket: Bool = false) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil, url.query == nil,
              url.scheme == (webSocket ? "wss" : "https") || (url.scheme == (webSocket ? "ws" : "http") && ["localhost", "127.0.0.1", "[::1]"].contains(host)) else {
            throw VoiceDraftError.message(webSocket
                ? "Use a full WSS endpoint, or WS on localhost for development. Do not put credentials in the URL."
                : "Use a full HTTPS endpoint, or HTTP on localhost for development. Do not put credentials in the URL.")
        }
        return url
    }
}
