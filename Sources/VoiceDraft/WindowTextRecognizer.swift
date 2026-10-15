import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import Vision
import VoiceDraftCore

/// Screen Recording permission for the optional window OCR fallback.
///
/// macOS has two separate gates. TCC's Screen Recording grant is what
/// `CGPreflightScreenCaptureAccess` reports and `CGRequestScreenCaptureAccess`
/// asks for. From macOS 15, ScreenCaptureKit also asks the user to approve
/// direct capture (replayd's "bypass the private window picker" alert, repeated
/// about monthly); preflight stays true while that alert is due, and the alert
/// appears at the first actual capture, not at a content query. So takes capture
/// only after this app session has completed one capture outside a take: from
/// the OCR switch, an Allow button, the Settings page, or launch with OCR on.
/// Takes only check; they never request or confirm.
enum ScreenRecordingPermission {
    private static let requestedKey = "screenRecordingRequested"
    private static let confirmation = Confirmation()

    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    /// True when takes may capture: TCC granted and, on macOS 14+, a capture
    /// outside a take succeeded in this app session. Never prompts.
    static var capturePermitted: Bool {
        guard granted else { return false }
        if #available(macOS 14, *) { return confirmation.confirmed }
        return true
    }

    /// From the OCR switch and Allow buttons only. Shows the TCC prompt when the
    /// permission is undetermined, surfaces the ScreenCaptureKit approval once it
    /// is granted, and opens Privacy & Security only for a repeated request that
    /// raised no system prompt (the permission was already denied).
    @MainActor static func request() {
        if granted { confirm(retry: true); return }
        let askedBefore = UserDefaults.standard.bool(forKey: requestedKey)
        UserDefaults.standard.set(true, forKey: requestedKey)
        if CGRequestScreenCaptureAccess() { confirm(retry: true); return }
        Task { @MainActor in
            // A system prompt takes key focus from VoiceDraft; give it a moment to appear.
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !granted, NSApp.isActive, #available(macOS 14, *) {
                // When CGRequest raised nothing, a content query asks for an undetermined permission.
                _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            if !granted, askedBefore, NSApp.isActive,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            // A grant in System Settings often needs a relaunch before preflight reports it.
            for _ in 0..<60 where !granted { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            if granted { confirm(retry: true) }
        }
    }

    /// Completes one minimal capture outside a take so any due ScreenCaptureKit
    /// approval alert appears now. Called from request(), the Settings page and
    /// launch when OCR is on. Does nothing until TCC is granted or once confirmed.
    /// Automatic callers try once per session, so a declined alert is not repeated;
    /// `retry` (the switch and Allow buttons) tries again.
    @MainActor static func confirm(retry: Bool = false) {
        guard granted else { return }
        if #available(macOS 14, *) {
            guard confirmation.begin(retry: retry) else { return }
            Task.detached(priority: .utility) {
                let confirmed = await probeCapture()
                confirmation.finish(confirmed)
            }
        }
    }

    /// A 2×2-pixel capture of the main display, discarded immediately; four
    /// averaged pixels carry no readable content. Only the capture, not the
    /// shareable-content query, counts as a use for the approval alert.
    @available(macOS 14, *)
    private static func probeCapture() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return false }
            let configuration = SCStreamConfiguration()
            configuration.width = 2; configuration.height = 2
            configuration.showsCursor = false
            _ = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                                           configuration: configuration)
            return true
        } catch { return false }
    }

    private final class Confirmation: @unchecked Sendable {
        private let lock = NSLock()
        private var state: (confirmed: Bool, running: Bool, attempted: Bool) = (false, false, false)
        var confirmed: Bool { lock.withLock { state.confirmed } }
        func begin(retry: Bool) -> Bool {
            lock.withLock {
                guard !state.confirmed, !state.running, retry || !state.attempted else { return false }
                state.running = true; state.attempted = true
                return true
            }
        }
        func finish(_ confirmed: Bool) { lock.withLock { state.confirmed = confirmed; state.running = false } }
    }
}

/// The captured window and, when known, the focused element's frame in
/// Vision's normalized window coordinates (origin bottom-left).
struct ScreenWindowLocation: Equatable, Sendable {
    var windowID: CGWindowID
    var focusFrame: CGRect?
}

/// Window OCR, injectable so the coordinator is testable without capture.
protocol WindowTextRecognizing: Sendable {
    /// Never prompts: TCC preflight plus this session's confirmation capture.
    func permitted() -> Bool
    func locate(_ request: ScreenReadRequest) async -> ScreenWindowLocation?
    func recognize(_ location: ScreenWindowLocation, deadline: ContinuousClock.Instant,
                   limits: ScreenContextLimits) async -> ScreenTextCollection?
}

/// Captures only one window (never the screen) and recognizes its text with
/// on-device Vision. The image is never written anywhere and is released after
/// recognition. One recognition runs at a time; a late result is discarded.
final class WindowTextRecognizer: WindowTextRecognizing, @unchecked Sendable {
    static let shared = WindowTextRecognizer()
    private let queue = DispatchQueue(label: "com.voicedraft.screen-ocr", qos: .utility)
    private let lookupQueue = DispatchQueue(label: "com.voicedraft.screen-window-lookup", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false

    func permitted() -> Bool { ScreenRecordingPermission.capturePermitted }

    private func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }
    private func release() { lock.lock(); busy = false; lock.unlock() }

    /// Window ID from the public window list (PID, layer, number and bounds need no
    /// Screen Recording; names are not read), matched to the AX window's frame.
    func locate(_ request: ScreenReadRequest) async -> ScreenWindowLocation? {
        await withCheckedContinuation { continuation in
            lookupQueue.async { continuation.resume(returning: Self.locateSync(pid: request.pid, request: request)) }
        }
    }

    private static func locateSync(pid: pid_t, request: ScreenReadRequest) -> ScreenWindowLocation? {
        func copy(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementSetMessagingTimeout(element, 0.05)
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        func frame(_ element: AXUIElement?) -> CGRect? {
            guard let element, let position = copy(element, kAXPositionAttribute), let size = copy(element, kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
            return CGRect(origin: point, size: extent)
        }
        var axWindow = request.window
        if axWindow == nil, AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(pid)
            for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                if let value = copy(app, name), CFGetTypeID(value) == AXUIElementGetTypeID() { axWindow = (value as! AXUIElement); break }
            }
        }
        let axFrame = frame(axWindow)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let windows: [(id: CGWindowID, bounds: CGRect)] = list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return (CGWindowID(number.uint32Value), bounds)
        }
        // Front-to-back order: prefer the AX window's frame within 2 pt, else the frontmost.
        let match = axFrame.flatMap { ax in
            windows.first { abs($0.bounds.minX - ax.minX) <= 2 && abs($0.bounds.minY - ax.minY) <= 2
                && abs($0.bounds.width - ax.width) <= 2 && abs($0.bounds.height - ax.height) <= 2 }
        } ?? windows.first
        guard let match else { return nil }
        var focus: CGRect?
        if let field = frame(request.focused), match.bounds.width > 0, match.bounds.height > 0 {
            let b = match.bounds
            focus = CGRect(x: (field.minX - b.minX) / b.width, y: 1 - (field.maxY - b.minY) / b.height,
                           width: field.width / b.width, height: field.height / b.height)
        }
        return ScreenWindowLocation(windowID: match.id, focusFrame: focus)
    }

    func recognize(_ location: ScreenWindowLocation, deadline: ContinuousClock.Instant,
                   limits: ScreenContextLimits) async -> ScreenTextCollection? {
        guard permitted(), ContinuousClock.now < deadline else { return nil }
        guard acquire() else { return nil }
        guard let image = await Self.capture(location.windowID, maxLongEdge: limits.ocrMaxPixelsLongEdge),
              ContinuousClock.now < deadline, !Task.isCancelled else { release(); return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequestRevision3
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = ScreenContextPolicy.ocrLanguages(
            interface: L10n.resolved(L10n.language), supported: (try? request.supportedRecognitionLanguages()) ?? [])
        request.minimumTextHeight = 0.008
        let box = RequestBox(request)
        let remaining = ContinuousClock.now.duration(to: deadline)
        let seconds = max(0, Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18)
        let observations: [VNRecognizedTextObservation]? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completion = OCRCompletion(continuation)
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { box.request.cancel(); completion.finish(nil) }
                // The busy flag clears only when Vision returns, so a slow recognition
                // cannot pile up work behind it; its late result is discarded.
                queue.async { [self] in
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    let result = (try? handler.perform([box.request])) != nil ? box.request.results : nil
                    release()
                    completion.finish(result)
                }
            }
        } onCancel: { box.request.cancel() }
        guard let observations, ContinuousClock.now < deadline else { return nil }
        return Self.collection(from: observations, focusFrame: location.focusFrame, limits: limits)
    }

    /// Lines top-to-bottom, then left-to-right; ranked by vertical distance to the
    /// focused field when its frame is known, so the excerpt starts near the caret.
    static func collection(from observations: [VNRecognizedTextObservation], focusFrame: CGRect?,
                           limits: ScreenContextLimits) -> ScreenTextCollection {
        var lines: [(text: String, box: CGRect)] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.4 else { return nil }
            let text = ScreenTextWalker.normalize(candidate.string, limit: limits.characterPerNode)
            return text.isEmpty ? nil : (text, observation.boundingBox)
        }
        lines.sort { abs($0.box.midY - $1.box.midY) > 0.005 ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX }
        if let focus = focusFrame {
            let enumerated = lines.enumerated().map { ($0.offset, $0.element) }
            lines = enumerated.sorted {
                let a = abs($0.1.box.midY - focus.midY), b = abs($1.1.box.midY - focus.midY)
                return a != b ? a < b : $0.0 < $1.0
            }.map(\.1)
        }
        var result = ScreenTextCollection()
        for line in lines {
            let room = limits.ocrCharacters - result.charactersCollected
            guard room > 0 else { result.truncated = true; break }
            let text = line.text.count > room ? String(line.text.prefix(room)) : line.text
            result.segments.append(ScreenTextSegment(kind: .ocrLine, text: text, order: result.segments.count))
            result.charactersCollected += text.count
        }
        result.nodesVisited = lines.count
        return result
    }

    /// One window only, scaled so the long edge is at most `maxLongEdge` pixels.
    private static func capture(_ windowID: CGWindowID, maxLongEdge: Int) async -> CGImage? {
        if #available(macOS 14, *) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                let size = fitted(CGSize(width: window.frame.width * scale, height: window.frame.height * scale), maxLongEdge: maxLongEdge)
                configuration.width = max(1, Int(size.width)); configuration.height = max(1, Int(size.height))
                configuration.showsCursor = false
                configuration.capturesAudio = false
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            } catch { return nil }
        } else {
            // Deprecated in macOS 14 and obsoleted in 15; reached only on macOS 13.
            // If a future SDK removes it, a one-frame SCStream with the same filter replaces it.
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) else { return nil }
            return downscaled(image, maxLongEdge: maxLongEdge)
        }
    }

    static func fitted(_ size: CGSize, maxLongEdge: Int) -> CGSize {
        let long = max(size.width, size.height)
        guard long > CGFloat(maxLongEdge), long > 0 else { return CGSize(width: size.width.rounded(), height: size.height.rounded()) }
        let factor = CGFloat(maxLongEdge) / long
        return CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
    }

    private static func downscaled(_ image: CGImage, maxLongEdge: Int) -> CGImage? {
        let size = fitted(CGSize(width: image.width, height: image.height), maxLongEdge: maxLongEdge)
        guard Int(size.width) != image.width || Int(size.height) != image.height else { return image }
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    private final class RequestBox: @unchecked Sendable {
        let request: VNRecognizeTextRequest
        init(_ request: VNRecognizeTextRequest) { self.request = request }
    }

    private final class OCRCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[VNRecognizedTextObservation]?, Never>?
        init(_ continuation: CheckedContinuation<[VNRecognizedTextObservation]?, Never>) { self.continuation = continuation }
        func finish(_ value: [VNRecognizedTextObservation]?) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
