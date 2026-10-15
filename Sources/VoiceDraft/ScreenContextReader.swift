import AppKit
import ApplicationServices
import VoiceDraftCore

/// What the AX reader needs from a take's captured target. `AXUIElement`
/// values are CF objects, which are safe to retain and pass between threads.
struct ScreenReadRequest: @unchecked Sendable {
    var pid: pid_t
    /// The take's captured window; nil looks up the focused, then main, window.
    var window: AXUIElement?
    var focused: AXUIElement?
    var focusedValue: String?
    var focusedRange: CFRange?
}

/// Reads a window's visible text. Injectable so the coordinator is testable.
protocol ScreenTextReading: Sendable {
    /// Nil when Accessibility is not allowed, no window exists, the reader is
    /// still busy with an earlier walk, or the wall timeout passed.
    func collect(_ request: ScreenReadRequest, limits: ScreenContextLimits) async -> ScreenTextCollection?
}

/// AX adapter over `ScreenTextWalker`. Walks run on one dedicated serial queue;
/// a blocked remote AX provider cannot queue more walks (the busy flag rejects
/// them) and a late result is discarded after the wall timeout, mirroring
/// `InsertionClipboardReader`. It never sets `AXEnhancedUserInterface` or
/// `AXManualAccessibility` on another app.
final class ScreenContextAXReader: ScreenTextReading, @unchecked Sendable {
    static let shared = ScreenContextAXReader()
    private let queue = DispatchQueue(label: "com.voicedraft.screen-context", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false

    func collect(_ request: ScreenReadRequest, limits: ScreenContextLimits) async -> ScreenTextCollection? {
        guard AXIsProcessTrusted() else { return nil }
        return await withCheckedContinuation { continuation in
            lock.lock()
            guard !busy else { lock.unlock(); continuation.resume(returning: nil); return }
            busy = true; lock.unlock()
            let completion = Completion(continuation)
            // An in-progress AX message can overrun the walker's own deadline by its timeout.
            DispatchQueue.global().asyncAfter(deadline: .now() + limits.axSeconds + 0.05) { completion.finish(nil) }
            queue.async { [self] in
                let collection = Self.walk(request, limits: limits)
                lock.lock(); busy = false; lock.unlock()
                completion.finish(collection)
            }
        }
    }

    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
    private static let attributeNames = [kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute,
                                         kAXDescriptionAttribute, "AXHidden", kAXChildrenAttribute] as CFArray

    /// Synchronous walk; runs on the reader queue only.
    static func walk(_ request: ScreenReadRequest, limits: ScreenContextLimits) -> ScreenTextCollection? {
        let timeout = limits.axMessageTimeout
        func fresh(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            let element = value as! AXUIElement
            AXUIElementSetMessagingTimeout(element, timeout)
            return element
        }
        func copy(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        let app = AXUIElementCreateApplication(request.pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let window = request.window.flatMap({ fresh($0) })
                ?? fresh(copy(app, kAXFocusedWindowAttribute)) ?? fresh(copy(app, kAXMainWindowAttribute)) else { return nil }
        let focused = request.focused.flatMap { fresh($0) }
        var childCache: [AXNode: [AXNode]] = [:]

        func string(_ value: CFTypeRef?) -> String? {
            guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
            return value as? String
        }
        func nodes(_ value: CFTypeRef?) -> [AXNode] {
            guard let value, CFGetTypeID(value) == CFArrayGetTypeID(), let array = value as? [AnyObject] else { return [] }
            // Children are capped per node, as for insertion's bounded traversal.
            return array.prefix(160).compactMap { fresh($0) }.map(AXNode.init)
        }
        func visibleText(_ element: AXUIElement) -> String? {
            guard let range = copy(element, kAXVisibleCharacterRangeAttribute), CFGetTypeID(range) == AXValueGetTypeID() else { return nil }
            var text: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, range, &text) == .success else { return nil }
            return string(text)
        }
        func attributes(_ node: AXNode) -> ScreenTextAttributes {
            let element = node.element
            var values: CFArray?
            var role = "", subrole = "", value: String?, title: String?, description: String?, hidden = false
            if AXUIElementCopyMultipleAttributeValues(element, attributeNames, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
               let list = values as? [AnyObject], list.count == 7 {
                // Missing attributes come back as AXValue error placeholders; `string` treats them as nil.
                role = string(list[0]) ?? ""; subrole = string(list[1]) ?? ""
                value = string(list[2]); title = string(list[3]); description = string(list[4])
                hidden = (list[5] as? Bool) == true
                childCache[node] = nodes(list[6])
            } else {
                role = string(copy(element, kAXRoleAttribute)) ?? ""
                subrole = string(copy(element, kAXSubroleAttribute)) ?? ""
                value = string(copy(element, kAXValueAttribute)); title = string(copy(element, kAXTitleAttribute))
                description = string(copy(element, kAXDescriptionAttribute))
                hidden = (copy(element, "AXHidden") as? Bool) == true
            }
            let secure = subrole == "AXSecureTextField"
            // Secure fields never expose a value or visible range to the walker.
            let visible = !secure && textRoles.contains(role) ? visibleText(element) : nil
            return ScreenTextAttributes(role: role, subrole: subrole, value: secure ? nil : value, title: title,
                                        description: description, visibleText: visible, hidden: hidden)
        }
        func children(_ node: AXNode, _ visibleOnly: Bool) -> [AXNode] {
            if visibleOnly {
                let visible = nodes(copy(node.element, "AXVisibleChildren"))
                if !visible.isEmpty { return visible }
            }
            if let cached = childCache[node] { return cached }
            let list = nodes(copy(node.element, kAXChildrenAttribute))
            childCache[node] = list
            return list
        }
        func parent(_ node: AXNode) -> AXNode? { fresh(copy(node.element, kAXParentAttribute)).map(AXNode.init) }

        let range = request.focusedRange.map { NSRange(location: $0.location, length: $0.length) }
        return ScreenTextWalker.collect(
            window: AXNode(window), windowTitle: string(copy(window, kAXTitleAttribute)),
            focused: focused.map(AXNode.init), focusedValue: request.focusedValue, focusedRange: range,
            attributes: attributes, children: children, parent: parent, limits: limits)
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ScreenTextCollection?, Never>?
        init(_ continuation: CheckedContinuation<ScreenTextCollection?, Never>) { self.continuation = continuation }
        func finish(_ value: ScreenTextCollection?) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

/// `AXUIElement` identity for the walker's visited set, by `CFEqual`/`CFHash`.
struct AXNode: Hashable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    static func == (lhs: AXNode, rhs: AXNode) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}
