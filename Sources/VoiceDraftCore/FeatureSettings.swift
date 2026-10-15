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
    case dictate, translate, edit, ask, styleSelection, insertLast
    public var id: String { rawValue }
    /// Actions understood by builds before `insertLast`. Those builds decode
    /// `DesktopOptions.shortcuts` strictly (an unknown raw value fails the whole
    /// device file) and accept at most five bindings, so newer actions are
    /// stored under a separate key that older builds ignore.
    static let legacy: Set<ShortcutAction> = [.dictate, .translate, .edit, .ask, .styleSelection]
    /// The writing mode a take started or retargeted by this action uses; nil
    /// for actions that never record (style selection, insert last result).
    public var recordingMode: WritingMode? {
        switch self {
        case .dictate: return .polish
        case .translate: return .translate
        case .edit: return .edit
        case .ask: return .ask
        case .styleSelection, .insertLast: return nil
        }
    }
}

/// Whether a running take may switch to another recording action while its
/// Fn chord is still held (see `FnChordTracker`). Mirrors the mode checks a
/// take makes when it starts; the caller keeps the current mode on a problem.
public enum TakeRetargetPolicy {
    public enum Problem: Equatable {
        /// The action does not record (style selection, insert last result).
        case notRecording
        /// Edit selection needs text selected when the take started.
        case needsSelection
        /// Non-verbatim modes need a writing-model key.
        case needsWritingKey
    }
    public static func problem(to action: ShortcutAction, selection: String, writingKey: String) -> Problem? {
        guard let mode = action.recordingMode else { return .notRecording }
        if mode != .verbatim, writingKey.isEmpty { return .needsWritingKey }
        if mode == .edit, selection.isEmpty { return .needsSelection }
        return nil
    }
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
        .init(.styleSelection, keyCode: 1, modifiers: 6), .init(.insertLast, keyCode: 9, modifiers: 6)
    ]
    /// Appends a default binding for every action missing from stored bindings
    /// (installs saved before that action existed). Stored bindings are kept as
    /// they are. An appended default that would collide with an enabled binding
    /// is appended disabled, so a migration never takes over a user's shortcut.
    public static func fillingDefaults(_ bindings: [Self]) -> [Self] {
        var result = bindings
        var used = Set(bindings.filter(\.enabled).map { "\($0.keyCode):\($0.modifiers)" })
        for binding in defaults where !result.contains(where: { $0.action == binding.action }) {
            var added = binding
            if added.enabled { added.enabled = used.insert("\(added.keyCode):\(added.modifiers)").inserted }
            result.append(added)
        }
        return result
    }
    /// Key code of the Fn (Globe) key. It is observed as a modifier through
    /// `flagsChanged`, alone or together with any of the four modifier bits
    /// (a chord such as Fn-Shift). Fn with a letter or other key is not
    /// supported: macOS reserves many Globe-letter shortcuts, and detecting
    /// them would require tapping every key press system-wide.
    public static let fnKeyCode: UInt32 = 63
    public var isFn: Bool { keyCode == Self.fnKeyCode }
    /// Fn alone or with any modifiers; any other key needs Control, Option or
    /// Command (Shift alone would capture ordinary typing).
    public var isAllowed: Bool {
        keyCode <= 127 && modifiers <= 15 && (isFn || modifiers & 14 != 0)
    }
    public enum Problem: Equatable {
        /// A normal key without Control, Option or Command, or an out-of-range value.
        case notAllowed
        /// Another enabled action already uses the same keys.
        case conflict(ShortcutAction)
    }
    /// Why `candidate` cannot replace the binding for its action among
    /// `bindings`, or nil when it can. Does not mutate or save anything.
    public static func problem(with candidate: Self, in bindings: [Self]) -> Problem? {
        guard candidate.enabled else { return nil }
        guard candidate.isAllowed else { return .notAllowed }
        if let other = bindings.first(where: {
            $0.action != candidate.action && $0.enabled && $0.keyCode == candidate.keyCode && $0.modifiers == candidate.modifiers
        }) { return .conflict(other.action) }
        return nil
    }
    /// Modifier symbols in the order ⌃⌥⇧⌘ followed by the key name, for
    /// example "⌃⌥Space", "Fn" or "⇧Fn". Ignores `enabled`.
    public var keyLabel: String {
        Self.modifierSymbols(modifiers) + (isFn ? "Fn" : Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }
    /// Modifier bits as symbols in the order ⌃⌥⇧⌘, e.g. 3 → "⌃⇧".
    public static func modifierSymbols(_ modifiers: UInt32) -> String {
        [(UInt32(2), "⌃"), (4, "⌥"), (1, "⇧"), (8, "⌘")].filter { modifiers & $0.0 != 0 }.map(\.1).joined()
    }
    private static let keyNames: [UInt32: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
        18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",
        34:"I",35:"P",36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"⇥",
        49:"Space",50:"`",51:"⌫",53:"⎋",123:"←",124:"→",125:"↓",126:"↑"
    ]
    public static func validate(_ bindings: [Self]) throws {
        guard bindings.count <= ShortcutAction.allCases.count, Set(bindings.map(\.action)).count == bindings.count else {
            throw FeatureError("Each action can have one shortcut.")
        }
        var used = Set<String>()
        for b in bindings where b.enabled {
            guard b.isAllowed, used.insert("\(b.keyCode):\(b.modifiers)").inserted else {
                throw FeatureError("Use distinct shortcuts with Control, Option or Command, or Fn.")
            }
        }
    }
}

/// Turns Fn (Globe) `flagsChanged` observations into shortcut press, release
/// and retarget events for bindings whose key is Fn, alone or in a chord.
///
/// - Activation needs Fn held, no active chord, and `armed`. It picks the
///   enabled Fn binding whose modifiers equal the held set exactly, at Fn's
///   press or when a modifier is added while Fn is held and nothing is active.
/// - While Fn stays held, a modifier press that completes another enabled Fn
///   binding exactly emits `.retarget(from:)` for it (no release or press), at
///   any time during the hold. Modifier releases never emit anything, so
///   letting go of Shift just before Fn keeps a promoted take. A set that
///   matches nothing keeps the current action and never ends a take.
/// - Only Fn's release sends the release, for whatever action is current.
/// - A new activation needs Fn released and pressed again. `armed` is false
///   only while Fn stays held after the active binding stopped being bound.
public struct FnChordTracker: Equatable {
    public struct Event: Equatable {
        public enum Kind: Equatable {
            case down, up
            /// The held chord now selects `action`; the take started by `from` continues.
            case retarget(from: ShortcutAction)
        }
        public let action: ShortcutAction
        public let kind: Kind
        public init(_ action: ShortcutAction, down: Bool) { self.action = action; kind = down ? .down : .up }
        public init(_ action: ShortcutAction, kind: Kind) { self.action = action; self.kind = kind }
        public static func retarget(from: ShortcutAction, to: ShortcutAction) -> Self { .init(to, kind: .retarget(from: from)) }
    }
    public private(set) var active: ShortcutAction?
    public private(set) var armed = true
    /// Modifiers held at the previous observation, to tell press edges from releases.
    private var previous: UInt32 = 0
    public init() {}

    /// - Parameters:
    ///   - fnHeld: whether the event flags contain the secondary-Fn mask.
    ///   - modifiers: held Shift = 1, Control = 2, Option = 4, Command = 8.
    ///   - bindings: all bindings; only enabled Fn bindings are considered.
    public mutating func observe(fnHeld: Bool, modifiers: UInt32, bindings: [ShortcutBinding]) -> [Event] {
        let held = modifiers & 15
        // A press edge: the held set grew (strict superset of the previous one).
        let pressedModifier = held != previous && held & previous == previous
        previous = held
        let match = bindings.first { $0.enabled && $0.isFn && $0.modifiers == held }
        if let action = active {
            let stillBound = bindings.contains { $0.action == action && $0.enabled && $0.isFn }
            if fnHeld && stillBound {
                guard pressedModifier, let match, match.action != action else { return [] }
                active = match.action
                return [.retarget(from: action, to: match.action)]
            }
            active = nil; armed = !fnHeld
            return [Event(action, down: false)]
        }
        guard fnHeld else { armed = true; return [] }
        guard armed, let match else { return [] }
        active = match.action
        return [Event(match.action, down: true)]
    }

    public mutating func reset() { self = Self() }
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
    /// A chord completed while the key is still held restarts the tap-versus-hold
    /// window, so Fn, Shift, release locks the promoted take just like a Shift-Fn tap.
    public mutating func retarget(at time: TimeInterval) { if downAt != nil { downAt = time } }
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
    /// On-screen context master switch ("Use on-screen text as context").
    public var screenContext = false
    /// Recognition hints consumer; effective only with `screenContext`.
    public var screenContextASR = true
    /// Writing reference consumer; effective only with `screenContext`.
    public var screenContextWriting = true
    /// Window OCR fallback; effective only with `screenContext` and Screen Recording.
    public var screenContextOCR = false
    /// User-added exclusions. Built-ins are `ScreenContextPolicy.builtInExcludedBundleIDs`.
    public var screenContextExcludedApps: [String] = []
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case shortcuts, additionalShortcuts, sounds, muteOutput, retainAudio, retentionDays, recentContext
        case onboardingCompleted, updateFeed, updatePublicKey, automaticUpdates
        case screenContext, screenContextASR, screenContextWriting, screenContextOCR, screenContextExcludedApps
    }
    /// Non-string exclusion entries are dropped rather than failing the file.
    private struct LossyString: Decodable {
        let value: String?
        init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(String.self) }
    }
    /// Unknown actions written by a newer build are skipped rather than failing the file.
    private struct LossyBinding: Decodable {
        let binding: ShortcutBinding?
        init(from decoder: Decoder) throws { binding = try? ShortcutBinding(from: decoder) }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stored = (try c.decodeIfPresent([LossyBinding].self, forKey: .shortcuts) ?? [])
            + (try c.decodeIfPresent([LossyBinding].self, forKey: .additionalShortcuts) ?? [])
        var seen = Set<ShortcutAction>()
        let bindings = stored.compactMap(\.binding).filter { seen.insert($0.action).inserted }
        shortcuts = c.contains(.shortcuts) ? ShortcutBinding.fillingDefaults(bindings) : ShortcutBinding.defaults
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? true
        muteOutput = try c.decodeIfPresent(Bool.self, forKey: .muteOutput) ?? false
        retainAudio = try c.decodeIfPresent(Bool.self, forKey: .retainAudio) ?? false
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 0
        recentContext = try c.decodeIfPresent(Bool.self, forKey: .recentContext) ?? false
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        updateFeed = try c.decodeIfPresent(String.self, forKey: .updateFeed) ?? ""
        updatePublicKey = try c.decodeIfPresent(String.self, forKey: .updatePublicKey) ?? ""
        automaticUpdates = try c.decodeIfPresent(Bool.self, forKey: .automaticUpdates) ?? false
        // Screen context fields decode leniently: a malformed value falls back to
        // the privacy-safe default instead of making device.json unreadable.
        screenContext = (try? c.decodeIfPresent(Bool.self, forKey: .screenContext)) ?? false
        screenContextASR = (try? c.decodeIfPresent(Bool.self, forKey: .screenContextASR)) ?? true
        screenContextWriting = (try? c.decodeIfPresent(Bool.self, forKey: .screenContextWriting)) ?? true
        screenContextOCR = (try? c.decodeIfPresent(Bool.self, forKey: .screenContextOCR)) ?? false
        let exclusions = (try? c.decodeIfPresent([LossyString].self, forKey: .screenContextExcludedApps)) ?? nil
        screenContextExcludedApps = ScreenContextPolicy.sanitizedExclusions((exclusions ?? []).compactMap(\.value))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Older builds decode `shortcuts` strictly and ignore unknown keys.
        try c.encode(shortcuts.filter { ShortcutAction.legacy.contains($0.action) }, forKey: .shortcuts)
        let additional = shortcuts.filter { !ShortcutAction.legacy.contains($0.action) }
        if !additional.isEmpty { try c.encode(additional, forKey: .additionalShortcuts) }
        try c.encode(sounds, forKey: .sounds); try c.encode(muteOutput, forKey: .muteOutput)
        try c.encode(retainAudio, forKey: .retainAudio); try c.encode(retentionDays, forKey: .retentionDays)
        try c.encode(recentContext, forKey: .recentContext); try c.encode(onboardingCompleted, forKey: .onboardingCompleted)
        try c.encode(updateFeed, forKey: .updateFeed); try c.encode(updatePublicKey, forKey: .updatePublicKey)
        try c.encode(automaticUpdates, forKey: .automaticUpdates)
        try c.encode(screenContext, forKey: .screenContext); try c.encode(screenContextASR, forKey: .screenContextASR)
        try c.encode(screenContextWriting, forKey: .screenContextWriting); try c.encode(screenContextOCR, forKey: .screenContextOCR)
        try c.encode(screenContextExcludedApps, forKey: .screenContextExcludedApps)
    }
    /// Screen context fields are sanitized at decode and never throw here:
    /// `DeviceSettings` validates on decode, so a throw would lose the whole file.
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
