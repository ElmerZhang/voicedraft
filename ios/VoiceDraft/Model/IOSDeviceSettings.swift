import Foundation
import VoiceDraftCore

/// Device-local options for iOS, the counterpart of the Mac `DeviceSettings`. Never synced.
/// Missing keys decode to their defaults so older files keep loading.
struct IOSDeviceSettings: Codable, Equatable {
    static let modes: [WritingMode] = [.polish, .translate, .ask]
    static let listeningTimeoutRange = 1...60

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
    var listeningTimeoutMinutes = 10
    var mode: WritingMode = .polish

    init() {}

    private enum CodingKeys: String, CodingKey {
        case serverURL, syncRevision, syncIdentity, dirty, lastSyncedAt, keepHistory, onboardingCompleted,
             listeningTimeoutMinutes, mode
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
        let timeout = try c.decodeIfPresent(Int.self, forKey: .listeningTimeoutMinutes) ?? defaults.listeningTimeoutMinutes
        listeningTimeoutMinutes = min(max(timeout, Self.listeningTimeoutRange.lowerBound), Self.listeningTimeoutRange.upperBound)
        let decodedMode = (try? c.decodeIfPresent(WritingMode.self, forKey: .mode)) ?? nil
        mode = decodedMode.flatMap { Self.modes.contains($0) ? $0 : nil } ?? defaults.mode
    }
}
