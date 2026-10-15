import Foundation
import CVoiceDraft

public enum DoubaoWire {
    public static func packet(_ data: Data, audio: Bool, final: Bool = false) -> Data {
        var result = Data([0x11, audio ? (final ? 0x22 : 0x20) : 0x10, audio ? 0 : 0x10, 0])
        var length = UInt32(data.count).bigEndian
        result.append(Data(bytes: &length, count: 4)); result.append(data); return result
    }
    /// Hotwords hold vocabulary first, then on-screen terms, up to 100.
    public static func start(profile: ModelProfile, vocabulary: AppVocabulary, screenTerms: [String] = []) throws -> Data {
        let extras = try profile.modelParameters()
        guard Set(extras.keys).isSubset(of: ["resource_id", "app_id", "language", "enable_itn", "enable_punc"]) else { throw FeatureError("Doubao options: resource_id, app_id, language, enable_itn, enable_punc.") }
        var request: [String: Any] = ["model_name": profile.model, "enable_itn": extras["enable_itn"] ?? true,
            "enable_punc": extras["enable_punc"] ?? true, "enable_ddc": false, "show_utterances": true, "result_type": "full"]
        let words = VocabularyProjection.make(vocabulary, for: .context, screenTerms: screenTerms).terms
        if !words.isEmpty {
            let context = try JSONSerialization.data(withJSONObject: ["hotwords": words.prefix(100).map { ["word": $0] }])
            request["corpus"] = ["context": String(decoding: context, as: UTF8.self)]
        }
        var audio: [String: Any] = ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1]
        if let language = extras["language"] { audio["language"] = language }
        return packet(try JSONSerialization.data(withJSONObject: ["user": ["uid": UUID().uuidString], "audio": audio, "request": request]), audio: false)
    }
    public static func response(_ data: Data) throws -> (text: String, final: Bool) {
        let b = [UInt8](data)
        guard b.count >= 8, b[0] >> 4 == 1 else { throw FeatureError("Invalid Doubao frame.") }
        let type = b[1] >> 4, flags = b[1] & 15, serialization = b[2] >> 4, compression = b[2] & 15
        var offset = Int(b[0] & 15) * 4
        guard offset >= 4 else { throw FeatureError("Invalid Doubao header.") }
        func integer(_ i: Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(b[i + $1]) } }
        if type == 15 {
            guard offset + 4 <= b.count else { throw FeatureError("Doubao rejected the speech request.") }
            throw FeatureError("Doubao speech error \(integer(offset)). Check credentials, resource ID and quota.")
        }
        guard type == 9, serialization == 1, flags <= 3, compression <= 1 else { throw FeatureError("Unsupported Doubao frame.") }
        if flags & 1 != 0 { offset += 4 }
        guard offset + 4 <= b.count else { throw FeatureError("Truncated Doubao frame.") }
        let length = integer(offset); offset += 4
        guard length <= 2_000_000, length == b.count - offset else { throw FeatureError("Invalid Doubao payload length.") }
        var payload = Data(b[offset...])
        if compression == 1 {
            var output = [UInt8](repeating: 0, count: 2_000_000), count = output.count
            let status = payload.withUnsafeBytes { source in
                vd_gunzip(source.bindMemory(to: UInt8.self).baseAddress, payload.count, &output, &count)
            }
            guard status == 0 else { throw FeatureError("Invalid or oversized compressed Doubao response.") }
            payload = Data(output.prefix(count))
        }
        guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw FeatureError("Invalid Doubao response.") }
        if let code = root["code"] as? Int, ![0, 1000, 20000000].contains(code) { throw FeatureError("Doubao speech error \(code).") }
        return ((root["result"] as? [String: Any])?["text"] as? String ?? "", flags & 2 != 0)
    }
}

private final class DoubaoConnection: @unchecked Sendable {
    let session: URLSession
    let socket: URLSessionWebSocketTask
    private let lock = NSLock()
    private var finishedAudio = false
    var uploaded: Bool { lock.withLock { finishedAudio } }
    func markUploaded() { lock.withLock { finishedAudio = true } }
    init(request: URLRequest) {
        session = URLSession(configuration: .ephemeral, delegate: HTTPTransport(), delegateQueue: nil)
        socket = session.webSocketTask(with: request); socket.maximumMessageSize = 2_000_016; socket.resume()
    }
    func cancel() { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}

public enum DoubaoSpeech {
    public static func connection(profile: ModelProfile, key: String) throws -> URLRequest {
        try profile.validateForInference()
        var request = URLRequest(url: try Endpoint.validate(profile.endpoint, webSocket: true), timeoutInterval: 30)
        let extras = try profile.modelParameters(), key = try QwenRequests.validKey(key, name: profile.name)
        if let app = extras["app_id"] as? String, !app.isEmpty {
            request.setValue(app, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(key, forHTTPHeaderField: "X-Api-Access-Key")
        } else { request.setValue(key, forHTTPHeaderField: "X-Api-Key") }
        request.setValue(extras["resource_id"] as? String ?? "volc.bigasr.sauc.duration", forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        return request
    }
    public static func transcribe(profile: ModelProfile, key: String, wav: Data, vocabulary: AppVocabulary,
                                  screenTerms: [String] = []) async throws -> String {
        let pcm = try WaveAudio.decode(wav)
        let audio = AsyncThrowingStream<Data, Error> { continuation in
            // Historical audio is finite and already bounded; live capture uses the backpressure feed.
            for offset in stride(from: 0, to: pcm.count, by: 3200) { continuation.yield(Data(pcm[offset..<min(offset + 3200, pcm.count)])) }
            continuation.finish()
        }
        return try await live(profile: profile, key: key, audio: audio, vocabulary: vocabulary, paced: true,
                              screenTerms: { screenTerms }, onReady: {}, onUpdate: { _ in })
    }
    public static func live(profile: ModelProfile, key: String, audio: AsyncThrowingStream<Data, Error>, vocabulary: AppVocabulary,
                            paced: Bool = false, screenTerms: @escaping @Sendable () async -> [String] = { [] },
                            onReady: @escaping @Sendable () async throws -> Void,
                            onUpdate: @escaping @Sendable (String) async -> Void) async throws -> String {
        // Configuration errors still throw before any socket opens.
        _ = try DoubaoWire.start(profile: profile, vocabulary: vocabulary)
        let client = DoubaoConnection(request: try connection(profile: profile, key: key))
        return try await withTaskCancellationHandler {
            defer { client.cancel() }
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    // The handshake is already in flight; await the gated terms provider, then build the frame.
                    let terms = await screenTerms()
                    try Task.checkCancellation()
                    let start = try DoubaoWire.start(profile: profile, vocabulary: vocabulary, screenTerms: terms)
                    try await client.socket.send(.data(start))
                    try await onReady()
                    var pending = Data()
                    for try await frame in audio {
                        try Task.checkCancellation()
                        if !pending.isEmpty {
                            try await client.socket.send(.data(DoubaoWire.packet(pending, audio: true)))
                            if paced { try await Task.sleep(nanoseconds: 100_000_000) }
                        }
                        pending = frame
                    }
                    client.markUploaded()
                    try await client.socket.send(.data(DoubaoWire.packet(pending, audio: true, final: true)))
                    return nil
                }
                group.addTask {
                    while true {
                        let message = try await client.socket.receive()
                        guard case .data(let data) = message else { throw FeatureError("Expected a binary Doubao response.") }
                        let result = try DoubaoWire.response(data)
                        if !result.text.isEmpty { await onUpdate(result.text) }
                        if result.final {
                            guard client.uploaded else { throw FeatureError("Doubao ended before the recording finished.") }
                            return try SpeechClient.transcript(result.text)
                        }
                    }
                }
                group.addTask { try await Task.sleep(nanoseconds: 660_000_000_000); throw FeatureError("Doubao recognition timed out.") }
                defer { group.cancelAll(); client.cancel() }
                while let result = try await group.next() {
                    if let result { return result }
                    group.addTask { try await Task.sleep(nanoseconds: 30_000_000_000); throw FeatureError("Doubao did not return the final result.") }
                }
                throw FeatureError("Doubao closed without a result.")
            }
        } onCancel: { client.cancel() }
    }
}
