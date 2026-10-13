import Foundation
import Security

public enum WaveAudio {
    public static func encode(_ pcm: Data) -> Data {
        var out = Data("RIFF".utf8)
        func u32(_ n: UInt32) { var value = n.littleEndian; out.append(Data(bytes: &value, count: 4)) }
        func u16(_ n: UInt16) { var value = n.littleEndian; out.append(Data(bytes: &value, count: 2)) }
        u32(UInt32(pcm.count + 36)); out.append(Data("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        out.append(Data("data".utf8)); u32(UInt32(pcm.count)); out.append(pcm); return out
    }
    public static func decode(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        func n(_ i: Int, _ count: Int) -> Int { (0..<count).reduce(0) { $0 | Int(b[i + $1]) << (8 * $1) } }
        guard b.count >= 44, String(bytes: b[0..<4], encoding: .ascii) == "RIFF", String(bytes: b[8..<12], encoding: .ascii) == "WAVE" else { throw FeatureError("Expected 16 kHz mono PCM WAV audio.") }
        var offset = 12, formatOK = false, pcm: Data?
        while offset + 8 <= b.count {
            let type = String(bytes: b[offset..<(offset + 4)], encoding: .ascii), size = n(offset + 4, 4)
            offset += 8
            guard size <= b.count - offset else { throw FeatureError("Truncated WAV audio.") }
            if type == "fmt " {
                formatOK = size >= 16 && n(offset, 2) == 1 && n(offset + 2, 2) == 1 && n(offset + 4, 4) == 16000 && n(offset + 14, 2) == 16
            } else if type == "data" { pcm = Data(b[offset..<(offset + size)]) }
            offset += size + size % 2
        }
        guard formatOK, let pcm, !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 19_300_000 else { throw FeatureError("Expected up to 10 minutes of 16 kHz mono PCM WAV audio.") }
        return pcm
    }
    /// At most 50 seconds per inline Google request. Prefer a quiet 20 ms boundary in the last 5 seconds.
    public static func chunks(_ pcm: Data, limit: Int = 1_600_000) -> [Data] {
        precondition(limit >= 640 && limit % 2 == 0)
        var result: [Data] = [], offset = 0
        while offset < pcm.count {
            var end = min(offset + limit, pcm.count)
            if end < pcm.count {
                var best = Int64.max
                for start in stride(from: max(offset + 640, end - 160_000), through: end - 640, by: 640) {
                    var energy: Int64 = 0
                    for i in stride(from: start, to: start + 640, by: 2) {
                        let sample = Int16(bitPattern: UInt16(pcm[i]) | UInt16(pcm[i + 1]) << 8)
                        energy += Int64(abs(Int(sample)))
                    }
                    if energy <= best { best = energy; end = start + 640 }
                }
            }
            result.append(Data(pcm[offset..<end])); offset = end
        }
        return result
    }
}

public enum WhisperRequests {
    public static func speech(profile: ModelProfile, key: String, wav: Data, vocabulary: AppVocabulary, boundary: String = UUID().uuidString) throws -> URLRequest {
        try profile.validateForInference(); try QwenRequests.validateAudio(wav)
        guard profile.adapter == .whisper else { throw FeatureError("Choose the Whisper protocol.") }
        let extras = try profile.modelParameters()
        guard Set(extras.keys).isSubset(of: ["language", "temperature", "prompt"]) else { throw FeatureError("Whisper options: language, temperature, prompt.") }
        var fields: [String: String] = ["model": profile.model, "response_format": "json"]
        for (name, value) in extras {
            guard value is String || value is NSNumber else { throw FeatureError("Whisper options must be strings or numbers.") }
            fields[name] = String(describing: value)
        }
        let context = VocabularyProjection.make(vocabulary, for: .context).context
        if !context.isEmpty { fields["prompt"] = [fields["prompt"] ?? "", String(context.prefix(1800))].filter { !$0.isEmpty }.joined(separator: "\n") }
        var body = Data()
        for name in fields.keys.sorted() {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(fields[name]!)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: try Endpoint.validate(profile.endpoint), timeoutInterval: 180)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("Bearer \(try QwenRequests.validKey(key, name: profile.name))", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }
    public static func parse(_ data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = object["text"] as? String else { throw FeatureError("Whisper returned an unexpected response.") }
        return try QwenRequests.nonempty(text)
    }
}

public enum GoogleSpeech {
    public static func request(profile: ModelProfile, token: String, pcm: Data, vocabulary: AppVocabulary) throws -> URLRequest {
        try profile.validateForInference()
        guard pcm.count <= 1_600_000 else { throw FeatureError("Google inline audio chunks must be shorter than 60 seconds.") }
        let extras = try profile.modelParameters()
        guard Set(extras.keys).isSubset(of: ["languageCodes", "features"]) else { throw FeatureError("Google options: languageCodes, features.") }
        var config: [String: Any] = ["autoDecodingConfig": [:], "model": profile.model,
            "languageCodes": extras["languageCodes"] ?? ["cmn-Hans-CN"]]
        if let features = extras["features"] { config["features"] = features }
        let words = VocabularyProjection.make(vocabulary, for: .context).terms
        if !words.isEmpty { config["adaptation"] = ["phraseSets": [["inlinePhraseSet": ["phrases": words.prefix(100).map { ["value": $0] }]]]] }
        var request = URLRequest(url: try Endpoint.validate(profile.endpoint), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try QwenRequests.validKey(token, name: profile.name))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["config": config, "content": WaveAudio.encode(pcm).base64EncodedString()])
        return request
    }
    public static func parse(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil else { throw FeatureError("Google Speech returned an invalid response.") }
        // Silence is legal for an individual chunk; require a nonempty combined transcript later.
        return (root["results"] as? [[String: Any]] ?? []).compactMap { ($0["alternatives"] as? [[String: Any]])?.first?["transcript"] as? String }.joined(separator: "\n")
    }
    public static func transcribe(profile: ModelProfile, credential: String, wav: Data, vocabulary: AppVocabulary) async throws -> String {
        let pcm = try WaveAudio.decode(wav)
        let token = try await GoogleCredential.accessToken(credential)
        var texts: [String] = []
        for chunk in WaveAudio.chunks(pcm) {
            try Task.checkCancellation()
            let (data, response) = try await HTTPTransport().send(request(profile: profile, token: token, pcm: chunk, vocabulary: vocabulary))
            try ProviderFailure.check(data, response: response)
            texts.append(try parse(data))
        }
        return try QwenRequests.nonempty(texts.filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}

public enum GoogleCredential {
    private static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    public static func accessToken(_ credential: String) async throws -> String {
        let text = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{") else { return try QwenRequests.validKey(text, name: "Google Speech") }
        guard text.utf8.count <= 64_000, let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              json["type"] as? String == "service_account", let email = json["client_email"] as? String,
              let pem = json["private_key"] as? String else { throw FeatureError("Paste a Google service account JSON key or a current OAuth access token.") }
        let derText = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("---") }.joined()
        guard let der = Data(base64Encoded: derText) else { throw FeatureError("Invalid Google private key.") }
        // SecItemImport accepts PKCS#8 PEM without writing a permanent Keychain item.
        var format = SecExternalFormat.formatPEMSequence, type = SecExternalItemType.itemTypePrivateKey
        var keys: CFArray?
        let status = SecItemImport(Data(pem.utf8) as CFData, nil, &format, &type, [], nil, nil, &keys)
        guard !der.isEmpty, status == errSecSuccess, let key = (keys as? [SecKey])?.first else { throw FeatureError("Could not read the Google service account private key.") }
        let now = Int(Date().timeIntervalSince1970)
        let header = base64URL(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"]))
        let claims = base64URL(try JSONSerialization.data(withJSONObject: ["iss": email, "scope": "https://www.googleapis.com/auth/cloud-platform", "aud": "https://oauth2.googleapis.com/token", "iat": now, "exp": now + 3600]))
        let signingInput = header + "." + claims
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(signingInput.utf8) as CFData, &error) else { throw FeatureError("Could not sign the Google access token request.") }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 30)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(signingInput).\(base64URL(signature as Data))".utf8)
        let (data, response) = try await HTTPTransport().send(request)
        guard response.statusCode == 200, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let token = root["access_token"] as? String else { throw FeatureError("Google authentication failed. Check the service account and enabled Speech API.") }
        return token
    }
}
