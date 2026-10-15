import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import Vision
import VoiceDraftCore

/// Screen Recording permission for the optional window OCR fallback.
/// A take only preflights; requests come from explicit Allow buttons and the OCR switch.
enum ScreenRecordingPermission {
    private static let requestedKey = "screenRecordingRequested"

    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time. macOS answers later calls with
    /// false and no prompt, so those open the Privacy & Security pane instead.
    @MainActor static func request() {
        guard !granted else { return }
        let askedBefore = UserDefaults.standard.bool(forKey: requestedKey)
        UserDefaults.standard.set(true, forKey: requestedKey)
        guard !CGRequestScreenCaptureAccess(), askedBefore,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
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
    /// Preflight only; never prompts.
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

    func permitted() -> Bool { ScreenRecordingPermission.granted }

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
