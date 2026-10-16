import Foundation
@testable import VoiceDraftCore

/// Text of a prompt message's content in either shape: a plain string, or the
/// cache-marked text blocks of the writing system message (concatenated).
func promptText(_ content: Any?) -> String? {
    if let string = content as? String { return string }
    guard let blocks = content as? [[String: Any]] else { return nil }
    return WritingClient.text(of: blocks)
}

/// The system and user messages of an unadapted writing request.
func writingMessages(_ request: URLRequest) throws -> (system: [String: Any], user: [String: Any]) {
    guard let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any],
          let messages = body["messages"] as? [[String: Any]], messages.count == 2 else {
        throw NSError(domain: "PromptTestSupport", code: 1)
    }
    return (messages[0], messages[1])
}
