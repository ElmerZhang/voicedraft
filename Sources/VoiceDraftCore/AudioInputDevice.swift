import Foundation

public struct AudioInputDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }

    public static func resolve(preferredID: String?, defaultID: String?, available: [Self]) throws -> Self {
        let id = preferredID ?? defaultID
        guard let selected = available.first(where: { $0.id == id }) else {
            if preferredID != nil { throw VoiceDraftError.message("The selected audio input is unavailable. Reconnect it or choose another device.") }
            throw VoiceDraftError.message("No audio input device is available. Connect a microphone and try again.")
        }
        return selected
    }
}
