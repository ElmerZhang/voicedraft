import Foundation

public struct FeatureError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct WritingStyle: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var prompt: String
    public init(id: UUID = UUID(), name: String, prompt: String) {
        self.id = id; self.name = name; self.prompt = prompt
    }
}

public enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    case dictate, translate, edit, ask, styleSelection
    public var id: String { rawValue }
}

public struct ShortcutBinding: Codable, Equatable, Identifiable {
    public var action: ShortcutAction
    public var keyCode: UInt32
    /// Shift = 1, Control = 2, Option = 4, Command = 8. A modifier-only Fn key uses keyCode 63.
    public var modifiers: UInt32
    public var enabled: Bool
    public var id: String { action.rawValue }
    public init(_ action: ShortcutAction, keyCode: UInt32, modifiers: UInt32, enabled: Bool = true) {
        self.action = action; self.keyCode = keyCode; self.modifiers = modifiers; self.enabled = enabled
    }
    public static let defaults: [Self] = [
        .init(.dictate, keyCode: 49, modifiers: 6), .init(.translate, keyCode: 17, modifiers: 6),
        .init(.edit, keyCode: 14, modifiers: 6), .init(.ask, keyCode: 0, modifiers: 6),
        .init(.styleSelection, keyCode: 1, modifiers: 6)
    ]
    public static func validate(_ bindings: [Self]) throws {
        guard bindings.count <= 5, Set(bindings.map(\.action)).count == bindings.count else {
            throw FeatureError("Each action can have one shortcut.")
        }
        var used = Set<String>()
        for b in bindings where b.enabled {
            guard b.keyCode <= 127, b.modifiers <= 15,
                  (b.keyCode == 63 && b.modifiers == 0) || (b.keyCode != 63 && b.modifiers & 14 != 0),
                  used.insert("\(b.keyCode):\(b.modifiers)").inserted else {
                throw FeatureError("Use distinct shortcuts with Control, Option or Command, or Fn alone.")
            }
        }
    }
}

/// A release can arrive while permission/network startup is still pending.
/// The caller retains .finish until capture has actually started.
public struct RecordingGesture {
    public enum Effect: Equatable { case none, start, finish }
    private var downAt: TimeInterval?
    public private(set) var locked = false
    public init() {}
    public mutating func press(at time: TimeInterval, idle: Bool) -> Effect {
        guard downAt == nil else { return .none }
        downAt = time
        if locked { locked = false; return .finish }
        return idle ? .start : .none
    }
    public mutating func release(at time: TimeInterval, active: Bool) -> Effect {
        guard let start = downAt else { return .none }
        downAt = nil
        guard active else { return .none }
        if time - start < 0.6 { locked = true; return .none }
        locked = false; return .finish
    }
    public mutating func reset() { downAt = nil; locked = false }
}

public struct DesktopOptions: Codable, Equatable {
    public var shortcuts = ShortcutBinding.defaults
    public var sounds = true
    public var muteOutput = false
    public var retainAudio = false
    public var retentionDays = 0
    public var recentContext = false
    public var onboardingCompleted = false
    public var updateFeed = ""
    public var updatePublicKey = ""
    public var automaticUpdates = false
    public init() {}
    public func validate() throws {
        try ShortcutBinding.validate(shortcuts)
        guard [0, 1, 7, 30, 90].contains(retentionDays) else { throw FeatureError("Choose a supported history retention period.") }
        if !updatePublicKey.isEmpty, Data(base64Encoded: updatePublicKey)?.count != 32 { throw FeatureError("Use a Base64 Ed25519 public key (32 bytes).") }
        if automaticUpdates && (updateFeed.isEmpty || updatePublicKey.isEmpty) { throw FeatureError("Set the HTTPS feed and public key before enabling automatic updates.") }
        if !updateFeed.isEmpty {
            let url = try Endpoint.validate(updateFeed)
            guard url.scheme == "https" else { throw FeatureError("Updates require HTTPS.") }
        }
    }
}

public struct RecentInputContext {
    private struct Item { let app: String; let text: String; let date: Date }
    private var items: [Item] = []
    public init() {}
    public mutating func clear() { items.removeAll() }
    public mutating func append(_ text: String, application: String, now: Date = Date()) {
        items.append(Item(app: application, text: String(text.prefix(2000)), date: now))
        items = Array(items.suffix(12))
    }
    public func text(application: String, now: Date = Date()) -> String {
        items.filter { $0.app == application && now.timeIntervalSince($0.date) < 1800 }
            .suffix(3).map(\.text).joined(separator: "\n---\n")
    }
}

extension SharedSettings {
    public func resolved(for bundleID: String?) -> SharedSettings {
        var copy = self
        let selected = bundleID.flatMap { applicationStyles[$0] } ?? selectedStyleID
        if let style = styles.first(where: { $0.id == selected }) { copy.stylePrompt = style.prompt }
        return copy
    }
}
