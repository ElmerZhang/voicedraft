import Foundation

public enum VoiceDraftError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public enum ModelRole: String, Codable, CaseIterable, Identifiable {
    case speech, writing
    public var id: String { rawValue }
    public var title: String { self == .speech ? "Speech recognition" : "Writing model" }
}

public struct ModelProfile: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var role: ModelRole
    public var endpoint: String
    public var model: String
    public var extraJSON: String

    public init(id: UUID = UUID(), name: String, role: ModelRole, endpoint: String, model: String, extraJSON: String = "{}") {
        self.id = id; self.name = name; self.role = role
        self.endpoint = endpoint; self.model = model; self.extraJSON = extraJSON
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
        case .verbatim: return "Transcribe"
        case .polish: return "Polish"
        case .translate: return "Translate"
        case .edit: return "Edit selection"
        case .ask: return "Ask"
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
    public var schemaVersion = 1
    public var profiles: [ModelProfile]
    public var speechID: UUID
    public var writingID: UUID
    public var hotwords = ""
    public var stylePrompt = "Preserve my tone and meaning. Be concise. Keep technical terms and mixed languages intact."
    public var targetLanguage = "English"

    public init() {
        let speech = ModelProfile.qwen(.speech), writing = ModelProfile.qwen(.writing)
        profiles = [speech, writing]; speechID = speech.id; writingID = writing.id
    }

    public var speech: ModelProfile? { profiles.first { $0.id == speechID && $0.role == .speech } }
    public var writing: ModelProfile? { profiles.first { $0.id == writingID && $0.role == .writing } }
    public var vocabulary: String {
        hotwords.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.prefix(300).joined(separator: ", ")
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw VoiceDraftError.message("This configuration needs a newer app.") }
        guard !profiles.isEmpty, profiles.count <= 50,
              Set(profiles.map(\.id)).count == profiles.count,
              speech != nil, writing != nil else {
            throw VoiceDraftError.message("Select a valid speech profile and writing profile.")
        }
        guard hotwords.utf8.count <= 30_000, stylePrompt.utf8.count <= 20_000,
              !targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceDraftError.message("Check the dictionary, style prompt, and target language.")
        }
        for p in profiles {
            _ = try Endpoint.validate(p.endpoint)
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
    public static func validate(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil, url.query == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)) else {
            throw VoiceDraftError.message("Use a full HTTPS endpoint, or HTTP on localhost for development. Do not put credentials in the URL.")
        }
        return url
    }
}
