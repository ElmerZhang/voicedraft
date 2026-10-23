import Foundation
import VoiceDraftCore

/// Device-local options for iOS, the counterpart of the Mac `DeviceSettings`. Never synced.
/// Missing keys decode to their defaults so older files keep loading.
struct IOSDeviceSettings: Codable, Equatable {
    static let modes: [WritingMode] = [.polish, .translate, .ask]
    /// Keyboard standby durations offered in Settings; 0 turns standby off.
    static let standbyOptions = [0, 5, 15, 30]

    var serverURL = ""
    /// Server revision of the last download or upload.
    var syncRevision = 0
    /// Hash of URL and token; a new connection restarts revision tracking, like the Mac.
    var syncIdentity = ""
    /// Local settings changed since the last sync.
    var dirty = true
    var lastSyncedAt: Date?
    var keepHistory = true
    var onboardingCompleted = false
    /// How long the app keeps the microphone open after a keyboard take starts, so the next keyboard take
    /// needs no app switch. Replaces the old `listeningTimeoutMinutes`, which older files may still contain.
    var keyboardStandbyMinutes = 15
    /// Fallback for standby: keep the microphone open for the whole window instead of the Picture in Picture
    /// keep-alive with the microphone closed between takes. Avoids background recording start failures; shows the indicator throughout.
    var standbyKeepsMicrophoneOpen = false
    var mode: WritingMode = .polish

    init() {}

    private enum CodingKeys: String, CodingKey {
        case serverURL, syncRevision, syncIdentity, dirty, lastSyncedAt, keepHistory, onboardingCompleted,
             keyboardStandbyMinutes, standbyKeepsMicrophoneOpen, mode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = IOSDeviceSettings()
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? defaults.serverURL
        syncRevision = try c.decodeIfPresent(Int.self, forKey: .syncRevision) ?? defaults.syncRevision
        syncIdentity = try c.decodeIfPresent(String.self, forKey: .syncIdentity) ?? defaults.syncIdentity
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? defaults.dirty
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        keepHistory = try c.decodeIfPresent(Bool.self, forKey: .keepHistory) ?? defaults.keepHistory
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? defaults.onboardingCompleted
        let standby = try c.decodeIfPresent(Int.self, forKey: .keyboardStandbyMinutes) ?? defaults.keyboardStandbyMinutes
        keyboardStandbyMinutes = Self.standbyOptions.contains(standby) ? standby : defaults.keyboardStandbyMinutes
        standbyKeepsMicrophoneOpen = try c.decodeIfPresent(Bool.self, forKey: .standbyKeepsMicrophoneOpen)
            ?? defaults.standbyKeepsMicrophoneOpen
        let decodedMode = (try? c.decodeIfPresent(WritingMode.self, forKey: .mode)) ?? nil
        mode = decodedMode.flatMap { Self.modes.contains($0) ? $0 : nil } ?? defaults.mode
    }
}
