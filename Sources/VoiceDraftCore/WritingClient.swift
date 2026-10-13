import Foundation

public enum WritingClient {
    /// Convert the common prompt (also used by vocabulary learning) into the selected wire protocol.
    public static func adapt(_ original: URLRequest, profile: ModelProfile, key: String, stream: Bool) throws -> URLRequest {
        var request = original
        guard var body = try JSONSerialization.jsonObject(with: original.httpBody ?? Data()) as? [String: Any],
              let messages = body["messages"] as? [[String: Any]] else { throw FeatureError("Invalid writing request.") }
        body["stream"] = stream
        switch profile.adapter {
        case .anthropic:
            body.removeValue(forKey: "messages")
            body["system"] = messages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }.joined(separator: "\n")
            body["messages"] = messages.filter { $0["role"] as? String != "system" }
            if body["max_tokens"] == nil { body["max_tokens"] = 4096 }
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(try QwenRequests.validKey(key, name: profile.name), forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .responses:
            body.removeValue(forKey: "messages")
            body["input"] = messages.map { message -> [String: Any] in
                ["role": message["role"] as? String ?? "user", "content": message["content"] as? String ?? ""]
            }
            body["store"] = false
        case .qwenChatWriting, .chatCompletions: break
        default: throw FeatureError("Choose a writing protocol.")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public static func complete(_ original: URLRequest, profile: ModelProfile, key: String,
                                onUpdate: (@Sendable (String) async -> Void)? = nil) async throws -> String {
        let request = try adapt(original, profile: profile, key: key, stream: onUpdate != nil)
        if let onUpdate {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await stream(request, adapter: profile.adapter, onUpdate: onUpdate) }
                group.addTask { try await Task.sleep(nanoseconds: 180_000_000_000); throw FeatureError("The writing request timed out.") }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }
        let (data, response) = try await HTTPTransport().send(request)
        try ProviderFailure.check(data, response: response)
        return try parse(data, adapter: profile.adapter)
    }

    public static func parse(_ data: Data, adapter: ModelAdapter) throws -> String {
        if adapter == .qwenChatWriting || adapter == .chatCompletions { return try QwenRequests.parse(data) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FeatureError("Invalid writing response.") }
        if adapter == .anthropic {
            guard ["end_turn", "stop_sequence"].contains(root["stop_reason"] as? String ?? "") else { throw FeatureError("The writing response is incomplete or contains tool calls.") }
            return try QwenRequests.nonempty((root["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined())
        }
        guard root["status"] as? String == "completed" else { throw FeatureError("The writing response is incomplete.") }
        return try QwenRequests.nonempty((root["output"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined())
    }

    static func stream(_ request: URLRequest, adapter: ModelAdapter,
                               onUpdate: @Sendable (String) async -> Void, configuration: URLSessionConfiguration = .ephemeral) async throws -> String {
        let config = configuration
        config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForResource = 180
        let delegate = HTTPTransport()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FeatureError("Writing service returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Check the model and credentials.")
        }
        // A gateway may ignore stream=true. Parse its bounded JSON response instead.
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            var data = Data()
            for try await byte in bytes { guard data.count < 2_000_000 else { throw FeatureError("Writing response too large.") }; data.append(byte) }
            let text = try parse(data, adapter: adapter); await onUpdate(text); return text
        }
        var parser = WritingStream(adapter: adapter), framer = SSEFramer(), size = 0
        var lastUpdate = Date.distantPast
        for try await byte in bytes {
            try Task.checkCancellation()
            size += 1
            guard size <= 4_000_000 else { throw FeatureError("Writing stream too large.") }
            if let frame = try framer.append(byte) {
                try parser.consume(event: frame.event, data: frame.data)
                if Date().timeIntervalSince(lastUpdate) > 0.04 { await onUpdate(parser.text); lastUpdate = Date() }
                if parser.complete { break }
            }
        }
        if !parser.complete, let frame = try framer.finish() { try parser.consume(event: frame.event, data: frame.data) }
        let result = try parser.finalText(); await onUpdate(result); return result
    }
}

/// Parses complete provider events after SSE framing.
public struct WritingStream {
    public let adapter: ModelAdapter
    public private(set) var text = ""
    public private(set) var complete = false
    private var validFinish = false
    public init(adapter: ModelAdapter) { self.adapter = adapter }
    public mutating func consume(event: String, data: String) throws {
        if data == "[DONE]" {
            guard validFinish else { throw FeatureError("Writing stream ended without a complete response.") }
            complete = true; return
        }
        guard let root = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { throw FeatureError("Invalid stream event.") }
        if root["error"] != nil || event == "error" { throw FeatureError("The writing service interrupted its response.") }
        switch adapter {
        case .anthropic:
            if let delta = root["delta"] as? [String: Any] {
                if delta["type"] as? String == "text_delta" { text += delta["text"] as? String ?? "" }
                if let reason = delta["stop_reason"] as? String {
                    guard ["end_turn", "stop_sequence"].contains(reason) else { throw FeatureError("The writing response was truncated or requires a tool.") }
                    validFinish = true
                }
            }
            if root["type"] as? String == "message_stop" { complete = validFinish }
        case .responses:
            let type = root["type"] as? String ?? event
            if type == "response.output_text.delta" { text += root["delta"] as? String ?? "" }
            if ["response.failed", "response.incomplete", "response.refusal.delta"].contains(type) { throw FeatureError("The writing response is incomplete or refused.") }
            if type == "response.completed", let response = root["response"] as? [String: Any] {
                let final = try WritingClient.parse(JSONSerialization.data(withJSONObject: response), adapter: .responses)
                text = final; complete = true
            }
        default:
            if let choice = (root["choices"] as? [[String: Any]])?.first {
                if let delta = choice["delta"] as? [String: Any] { text += delta["content"] as? String ?? "" }
                if let reason = choice["finish_reason"] as? String {
                    guard reason == "stop" else { throw FeatureError("The writing response was truncated, filtered or requires a tool.") }
                    validFinish = true
                    // Some compatible services close immediately after the finish event.
                    complete = true
                }
            }
        }
        guard text.utf8.count <= 1_000_000 else { throw FeatureError("Writing response too large.") }
    }
    public func finalText() throws -> String {
        guard complete else { throw FeatureError("The connection ended before writing completed.") }
        return try QwenRequests.nonempty(text)
    }
}

public enum ModelDiscovery {
    public static func request(profile: ModelProfile, key: String, after: String? = nil) throws -> URLRequest {
        guard !profile.adapter.isWebSocket, profile.adapter != .googleSpeech else { throw FeatureError("This speech protocol does not publish a model list. Enter a model ID.") }
        let endpoint = try Endpoint.validate(profile.endpoint)
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let endings = ["/chat/completions", "/audio/transcriptions", "/messages", "/responses", "/services/aigc/multimodal-generation/generation"]
        guard let suffix = endings.first(where: { parts.path.hasSuffix($0) }) else { throw FeatureError("The endpoint needs a known inference path to discover models.") }
        parts.path = String(parts.path.dropLast(suffix.count)) + "/models"
        if profile.adapter == .anthropic {
            parts.queryItems = [URLQueryItem(name: "limit", value: "100")]
            if let after { parts.queryItems?.append(URLQueryItem(name: "after_id", value: after)) }
        }
        var request = URLRequest(url: parts.url!, timeoutInterval: 30)
        let key = try QwenRequests.validKey(key, name: profile.name)
        request.setValue(key, forHTTPHeaderField: profile.adapter == .anthropic ? "x-api-key" : "Authorization")
        if profile.adapter == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        else { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }
    public static func fetch(profile: ModelProfile, key: String) async throws -> [String] {
        var ids = Set<String>(), after: String?
        for _ in 0..<20 {
            let (data, response) = try await HTTPTransport().send(request(profile: profile, key: key, after: after))
            try ProviderFailure.check(data, response: response)
            guard data.count <= 2_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = root["data"] as? [[String: Any]] else { throw FeatureError("The service did not return a model list.") }
            ids.formUnion(items.compactMap { $0["id"] as? String }.filter { !$0.isEmpty && $0.count <= 256 })
            guard profile.adapter == .anthropic, root["has_more"] as? Bool == true else { return ids.sorted() }
            guard let next = root["last_id"] as? String, next != after else { throw FeatureError("Invalid model list pagination.") }
            after = next
        }
        throw FeatureError("The model list exceeded the page limit.")
    }
}

/// Unlike URLSession.AsyncBytes.lines, this preserves blank lines delimiting SSE events.
struct SSEFramer {
    struct Frame { let event: String; let data: String }
    private var line = Data()
    private var event = ""
    private var payload: [String] = []
    mutating func append(_ byte: UInt8) throws -> Frame? {
        if byte == 10 { return try consumeLine() }
        guard line.count < 1_000_000 else { throw FeatureError("SSE line too large.") }
        line.append(byte); return nil
    }
    private mutating func consumeLine() throws -> Frame? {
        if line.last == 13 { line.removeLast() }
        guard let value = String(data: line, encoding: .utf8) else { throw FeatureError("Invalid UTF-8 in writing stream.") }
        line.removeAll(keepingCapacity: true)
        if value.isEmpty { return flush() }
        if value.hasPrefix("data:") {
            var data = String(value.dropFirst(5)); if data.first == " " { data.removeFirst() }; payload.append(data)
        } else if value.hasPrefix("event:") { event = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        return nil
    }
    private mutating func flush() -> Frame? {
        defer { event = ""; payload.removeAll(keepingCapacity: true) }
        return payload.isEmpty ? nil : Frame(event: event, data: payload.joined(separator: "\n"))
    }
    mutating func finish() throws -> Frame? {
        if !line.isEmpty, let frame = try consumeLine() { return frame }
        return flush()
    }
}
