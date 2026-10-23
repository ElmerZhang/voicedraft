import AVFoundation
import AVKit
import UIKit
#if DEBUG
import ObjectiveC
#endif

/// Events the standby policy in `AppModel` reacts to. Delivered on the main queue.
enum StandbyAudioEvent: Equatable {
    /// An interruption (a call, Siri, another app's non-mixable audio) began; the system deactivated the session.
    /// The Picture in Picture window stays up.
    case interruptionBegan
    /// The interruption ended; the session may be activated again.
    case interruptionEnded
    /// `mediaServicesWereResetNotification`: the session must be configured and activated again.
    case mediaServicesReset
    /// The Picture in Picture window closed without returning to VoiceDraft: the user tapped its close button or
    /// the system ended it. The app is no longer kept resident, so standby ends.
    case keepAliveEnded
    /// The Picture in Picture window could not start (`failedToStartPictureInPictureWithError`); the text names it.
    case keepAliveFailed(String)
    /// Actual PiP readiness changed; preparing a controller alone does not keep an app alive.
    case readinessChanged
}

/// Keeps the app resident during the standby window while the microphone is closed. `AppModel` depends on this
/// protocol so the standby state machine is tested with a fake.
protocol StandbyKeepAlive: AnyObject {
    var isRunning: Bool { get }
    var isReadyForBackground: Bool { get }
    /// The controller can transition when leaving the app; didStart may arrive only after that transition.
    var isPreparedForBackgroundTransition: Bool { get }
    /// Session and window events, whether or not the keep-alive is running, so an interruption's end is never
    /// missed.
    var onEvent: ((StandbyAudioEvent) -> Void)? { get set }
    /// Activates the shared `.playAndRecord` session if needed and starts keeping the app resident. Also safe to
    /// call while running: it then only activates the session again (after an interruption or a reset).
    func start() throws
    /// Stops keeping the app resident. With `deactivatingSession` the audio session is deactivated as well.
    func stop(deactivatingSession: Bool)
    /// Whether a take is recording, for whatever the keep-alive shows the user.
    func setRecording(_ recording: Bool)
}

extension StandbyKeepAlive {
    var isReadyForBackground: Bool { isRunning }
    var isPreparedForBackgroundTransition: Bool { isReadyForBackground }
    func setRecording(_ recording: Bool) {}
}

/// Keeps standby resident with a video-call Picture in Picture window (`AVPictureInPictureController` with an
/// `activeVideoCallSourceView` content source), following AgenBoard's published approach. Typeless documents a
/// similar Picture in Picture experience but does not publish its internal implementation.
///
/// - `start()` (only possible in the foreground) activates the shared session and creates the controller around a
///   clear 1×1 pt source view in the key window. Explicit start happens only while the source scene is active.
///   Device evidence: calling from `willResignActive` fails with AVKitErrorDomain(-1001).
/// - The audio session stays active for as long as the keep-alive runs: deactivating it ends video-call Picture in
///   Picture. No audio engine runs between takes; the microphone
///   engine is built for each take and discarded after it.
/// - The window closing on its own or by the user (not a return to the app) is reported as `.keepAliveEnded`.
/// - Debug uses a subpixel content height and a runtime-checked private controls setter to hide the window
///   without stashing it at the screen edge. Release retains the visible window. See `docs/ios.md` for evidence.
///
/// Every UIKit and AVKit call runs on the main thread: `AppModel` calls in on the main actor, and the delegate and
/// notification callbacks arrive on the main queue.
final class IOSPictureInPictureKeepAlive: NSObject, StandbyKeepAlive {
    var onEvent: ((StandbyAudioEvent) -> Void)?
    private(set) var isRunning = false
    private(set) var isReadyForBackground = false
    var isPreparedForBackgroundTransition: Bool {
        isRunning && (controller?.isPictureInPicturePossible == true || isReadyForBackground)
    }

    private let sessionController: IOSAudioSessionController
    private var controller: AVPictureInPictureController?
    private var contentController: StandbyPictureInPictureContentController?
    private var sourceView: UIView?
    private var observers: [NSObjectProtocol] = []
    /// Set when iOS asks to restore the app's interface: the stop that follows is a return to VoiceDraft, not an end.
    private var restoring = false
    private var recording = false
    private var possibleObservation: NSKeyValueObservation?
    private var startTimer: Timer?
    private var startDeadline: Date?
    private var startRequested = false
    static var hidesWindowByDefault: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    private var hidesWindow: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--standby-device-probe"),
           ProcessInfo.processInfo.arguments.contains("--probe-visible-pip") { return false }
        #endif
        return Self.hidesWindowByDefault
    }

    init(sessionController: IOSAudioSessionController) {
        self.sessionController = sessionController
        super.init()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            self?.onEvent?(type == .began ? .interruptionBegan : .interruptionEnded)
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            self?.onEvent?(.mediaServicesReset)
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startWindowIfPossible() }
        })
    }

    deinit {
        startTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() throws {
        try sessionController.activate()
        try MainActor.assumeIsolated {
            if controller == nil { try makeController() }
        }
        isRunning = true
        KeyboardDiagnostics.record("pip.prepared", "possible=\(controller?.isPictureInPicturePossible == true)")
        MainActor.assumeIsolated { scheduleStart() }
    }

    func stop(deactivatingSession: Bool) {
        // Marked first, so the delegate's stop callback for this programmatic stop is not reported as an end.
        isRunning = false
        isReadyForBackground = false
        startRequested = false
        startTimer?.invalidate()
        startTimer = nil
        startDeadline = nil
        possibleObservation = nil
        restoring = false
        MainActor.assumeIsolated {
            controller?.stopPictureInPicture()
            controller?.delegate = nil
            controller = nil
            contentController = nil
            sourceView?.removeFromSuperview()
            sourceView = nil
        }
        if deactivatingSession { sessionController.deactivate() }
    }

    func setRecording(_ recording: Bool) {
        guard self.recording != recording else { return }
        self.recording = recording
        MainActor.assumeIsolated { contentController?.setRecording(recording) }
    }

    @MainActor
    private func makeController() throws {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            throw AudioStepError(step: "standby: picture in picture", underlying: CocoaError(.featureUnsupported))
        }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        guard let window else {
            throw AudioStepError(step: "standby: picture in picture",
                                 underlying: VoiceDraftPictureInPictureError.noWindow)
        }
        let source = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        source.backgroundColor = .clear
        source.isUserInteractionEnabled = false
        source.isAccessibilityElement = false
        window.addSubview(source)

        let content = StandbyPictureInPictureContentController()
        // The development build uses a subpixel height, which the device rounds down to zero. The system
        // session stays active without entering the stashed state that draws the screen-edge arrow.
        content.preferredContentSize = hidesWindow ? CGSize(width: 300, height: 0.1) : CGSize(width: 240, height: 135)
        content.setRecording(recording)
        content.loadViewIfNeeded()
        if hidesWindow {
            content.view.frame = CGRect(origin: .zero, size: content.preferredContentSize)
            content.view.backgroundColor = .clear
            content.view.isOpaque = false
            content.view.clipsToBounds = true
            content.view.subviews.forEach { $0.isHidden = true }
        }
        let controller = AVPictureInPictureController(
            contentSource: .init(activeVideoCallSourceView: source, contentViewController: content))
        #if DEBUG
        if hidesWindow {
            // API research: https://github.com/Yoroin/GlobalRefresh-PiP (Yoroin), based on
            // https://github.com/CaiWanFeng/PiP (CaiWanFeng). Independent implementation; no dependency or hooks.
            let selector = NSSelectorFromString("setControlsStyle:")
            guard let method = class_getInstanceMethod(type(of: controller), selector),
                  method_getNumberOfArguments(method) == 3,
                  let argument = method_copyArgumentType(method, 2) else {
                source.removeFromSuperview()
                throw VoiceDraftPictureInPictureError.hiddenStandbyUnavailable
            }
            let result = method_copyReturnType(method)
            defer { free(result); free(argument) }
            guard String(cString: result) == "v", String(cString: argument) == "q" else {
                source.removeFromSuperview()
                throw VoiceDraftPictureInPictureError.hiddenStandbyUnavailable
            }
            typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
            unsafeBitCast(method_getImplementation(method), to: Setter.self)(controller, selector, 2)
            KeyboardDiagnostics.record("pip.hidden.configured", "height=0.1 controlsStyle=2")
        }
        #endif
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        sourceView = source
        contentController = content
        self.controller = controller
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.startWindowIfPossible() }
        }
    }

    @MainActor
    private func scheduleStart() {
        guard !isReadyForBackground, startTimer == nil else { return }
        startDeadline = Date().addingTimeInterval(5)
        startTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                // On this OS didStart can wait for the foreground-to-background transition. A prepared
                // foreground controller must not expire just because the user stays on the Home screen.
                if UIApplication.shared.applicationState != .background,
                   self.controller?.isPictureInPicturePossible == true {
                    self.startDeadline = Date().addingTimeInterval(5)
                }
                if let deadline = self.startDeadline, Date() >= deadline {
                    self.stop(deactivatingSession: false)
                    self.onEvent?(.keepAliveFailed("standby: picture in picture startup timed out"))
                    KeyboardDiagnostics.record("pip.timeout")
                } else {
                    self.startWindowIfPossible()
                }
            }
        }
        startWindowIfPossible()
    }

    @MainActor
    private func startWindowIfPossible() {
        // Device evidence: starting from willResignActive fails with AVKitErrorDomain(-1001).
        // Both the application and this source's scene must still be foreground-active.
        guard isRunning, !startRequested, UIApplication.shared.applicationState == .active,
              sourceView?.window?.windowScene?.activationState == .foregroundActive,
              let controller, !controller.isPictureInPictureActive,
              controller.isPictureInPicturePossible else { return }
        restoring = false
        startRequested = true
        KeyboardDiagnostics.record("pip.start.request", "foregroundActive=true")
        controller.startPictureInPicture()
    }
}

enum VoiceDraftPictureInPictureError: LocalizedError {
    case noWindow
    case hiddenStandbyUnavailable
    var errorDescription: String? {
        switch self {
        case .noWindow: "no key window"
        case .hiddenStandbyUnavailable: AppText.t("Hidden standby is unavailable on this iOS version.")
        }
    }
}

extension IOSPictureInPictureKeepAlive: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard isRunning, pictureInPictureController === controller else { return }
        startTimer?.invalidate()
        startTimer = nil
        startDeadline = nil
        startRequested = false
        isReadyForBackground = true
        KeyboardDiagnostics.record("pip.didStart")
        if hidesWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak pictureInPictureController] in
                // Returning to the app can restore the content before this delayed check. Only inspect an
                // active PiP window, not the restored foreground view or an already-ended standby session.
                guard let self, self.controller === pictureInPictureController, self.isRunning,
                      self.isReadyForBackground, pictureInPictureController?.isPictureInPictureActive == true else { return }
                let view = self.contentController?.view
                KeyboardDiagnostics.record("pip.hidden.geometry", "content=\(String(describing: view?.bounds)) window=\(String(describing: view?.window?.bounds)) active=\(self.isReadyForBackground) suspended=\(pictureInPictureController?.isPictureInPictureSuspended == true)")
                guard let window = view?.window, window.bounds.height * window.screen.scale < 1 else {
                    // A runtime that clamps to a visible minimum has not met the hidden-standby contract.
                    self.stop(deactivatingSession: false)
                    self.onEvent?(.keepAliveFailed(VoiceDraftPictureInPictureError.hiddenStandbyUnavailable.localizedDescription))
                    return
                }
            }
        }
        onEvent?(.readinessChanged)
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // The user tapped the window to return, or came back to the app: standby continues and the window comes
        // back the next time the user leaves.
        restoring = true
        completionHandler(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let wasRestore = restoring
        restoring = false
        guard isRunning, pictureInPictureController === controller else { return }
        isReadyForBackground = false
        startRequested = false
        onEvent?(.readinessChanged)
        // A stop while VoiceDraft is coming to the foreground is a return to the app, even without a restore call.
        let inBackground = MainActor.assumeIsolated { UIApplication.shared.applicationState == .background }
        if wasRestore || !inBackground {
            MainActor.assumeIsolated { scheduleStart() }
            return
        }
        // Closed with its close button or ended by the system. The controller is gone with the window.
        stop(deactivatingSession: false)
        onEvent?(.keepAliveEnded)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        guard isRunning, pictureInPictureController === controller else { return }
        KeyboardDiagnostics.record("pip.failed", KeyboardDiagnostics.error(error))
        stop(deactivatingSession: false)
        onEvent?(.keepAliveFailed(AudioStepError.describe(
            AudioStepError(step: "standby: picture in picture", underlying: error))))
    }
}

/// The Picture in Picture window's content: a microphone symbol and a status line. A plain UIKit view hierarchy
/// rendered live by the video-call window; nothing is captured or played.
final class StandbyPictureInPictureContentController: AVPictureInPictureVideoCallViewController {
    private let symbol = UIImageView()
    private let label = UILabel()
    private var recording = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        symbol.tintColor = .white
        symbol.contentMode = .scaleAspectFit
        symbol.preferredSymbolConfiguration = .init(pointSize: 36, weight: .medium)
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        let stack = UIStackView(arrangedSubviews: [symbol, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
        ])
        render()
    }

    func setRecording(_ recording: Bool) {
        self.recording = recording
        if isViewLoaded { render() }
    }

    private func render() {
        symbol.image = UIImage(systemName: recording ? "mic.fill" : "mic")
        symbol.tintColor = recording ? .systemRed : .white
        label.text = recording ? AppText.t("Recording") : AppText.t("VoiceDraft on standby")
    }
}
