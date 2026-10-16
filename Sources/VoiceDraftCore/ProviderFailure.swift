import Foundation

public enum ProviderFailure {
    // Never render arbitrary provider messages: they can echo keys, prompts, or audio data URLs.
    private static let codes: Set<String> = [
        "InvalidApiKey", "InvalidParameter", "InvalidParameterValue", "InvalidRequest", "BadRequest",
        "ModelNotFound", "InvalidModel", "UnsupportedModel", "AccessDenied", "Forbidden",
        "Throttling", "Throttling.RateQuota", "Throttling.AllocationQuota", "QuotaExceeded",
        "DataInspectionFailed", "InternalError", "ServiceUnavailable", "CLIENT_ERROR", "SERVER_ERROR",
        "InvalidTask", "TaskFailed", "InvalidInput", "UnsupportedFormat", "InvalidSampleRate"
    ]
    public static func check(_ data: Data, response: HTTPURLResponse) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let error = root["error"] as? [String: Any] ?? root
        let code = error["code"] as? String
        let requestID = root["request_id"] as? String ?? response.value(forHTTPHeaderField: "x-request-id")
        throw http(status: response.statusCode, code: code, requestID: requestID)
    }
    /// The usage log reads the status from this message's first argument.
    static let httpKeyPrefix = "Model request failed (HTTP "
    public static func http(status: Int, code: String? = nil, requestID: String? = nil) -> VoiceDraftError {
        let hint: String
        switch status {
        case 401, 403: hint = L("Check the API key, its region, and model access.")
        case 404: hint = L("Check the full endpoint URL and selected model.")
        case 429: hint = L("Rate limit or quota reached. Try again later.")
        case 400: hint = L("Check the selected model, its protocol, and advanced parameters in Models.")
        case 300..<400: hint = L("Redirects are blocked. Use the provider's direct endpoint.")
        default: hint = L("Try again or check the provider console.")
        }
        return .message("Model request failed (HTTP \(status)). \(hint)\(details(code: code, requestID: requestID))")
    }
    static let webSocketKey = "Speech task failed. Check the model, API key region, and advanced parameters.{0}"
    static func webSocket(_ header: [String: Any], taskID: String) -> VoiceDraftError {
        .message("Speech task failed. Check the model, API key region, and advanced parameters.\(details(code: header["error_code"] as? String, requestID: taskID))")
    }
    /// English, language-independent description of a provider failure for the usage log: the HTTP
    /// status or task failure plus the recognized provider code and UUID request ID. Nil for other messages.
    static func logDescription(_ message: LocalizedMessage) -> String? {
        var parts: [String]
        var detailArguments = message.arguments
        if message.key.hasPrefix(httpKeyPrefix), let status = detailArguments.first {
            parts = ["Model request failed (HTTP \(status))."]; detailArguments.removeFirst()
        } else if message.key == webSocketKey {
            parts = ["Speech task failed."]
        } else { return nil }
        let tokens = detailArguments
            .flatMap { $0.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0))) }) }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        if let code = tokens.first(where: codes.contains) { parts.append("code=\(code)") }
        if let id = tokens.lazy.compactMap(UUID.init(uuidString:)).first { parts.append("requestID=\(id.uuidString)") }
        return parts.joined(separator: " ")
    }
    private static func details(code: String?, requestID: String?) -> String {
        var result = ""
        if let code, codes.contains(code) { result += L(" Provider code: \(code).") }
        if let requestID, let uuid = UUID(uuidString: requestID) { result += L(" Request ID: \(uuid.uuidString).") }
        return result
    }
}
