import Foundation

public struct DeviceSettings: Codable {
    public var inputDeviceID: String? = nil
    public var inputDeviceName: String? = nil
    public var serverURL = "http://127.0.0.1:8765"
    public var autoSync = false
    public var autoPaste = true
    public var keepHistory = true
    public var syncRevision = 0
    public var syncIdentity = ""
    public var dirty = true
    public var features = DesktopOptions()
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case inputDeviceID, inputDeviceName, serverURL, autoSync, autoPaste, keepHistory, syncRevision, syncIdentity, dirty, features
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputDeviceID = try c.decodeIfPresent(String.self, forKey: .inputDeviceID)
        inputDeviceName = try c.decodeIfPresent(String.self, forKey: .inputDeviceName)
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? "http://127.0.0.1:8765"
        autoSync = try c.decodeIfPresent(Bool.self, forKey: .autoSync) ?? false
        autoPaste = try c.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? true
        keepHistory = try c.decodeIfPresent(Bool.self, forKey: .keepHistory) ?? true
        syncRevision = try c.decodeIfPresent(Int.self, forKey: .syncRevision) ?? 0
        syncIdentity = try c.decodeIfPresent(String.self, forKey: .syncIdentity) ?? ""
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? true
        features = try c.decodeIfPresent(DesktopOptions.self, forKey: .features) ?? DesktopOptions()
        try features.validate()
    }
}
