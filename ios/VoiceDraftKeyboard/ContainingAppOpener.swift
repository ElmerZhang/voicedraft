import UIKit

/// Opens the containing app from the keyboard. `docs/ios.md` (flow 3) explains why there is more than one way.
///
/// Strategies, in order, stopping at the first success (`KeyboardOpenSequence`):
/// 1. `NSExtensionContext.open`. On iOS 27.0.1 it reported false for this keyboard.
/// 2. Walk the responder chain from the input view controller to the extension process's `UIApplication` (checked
///    by class, never just by selector) and call its public `openURL:options:completionHandler:`, or `openURL:`. This is what the keyboard ecosystem (for example KeyboardKit) does.
/// 3. Look up `UIApplication` by name, read `sharedApplication` through key-value coding, and make the same call.
/// Each strategy is retried once with the scheme spelled `VoiceDraft://`, only after the lower-case form failed.
///
/// `UIApplication.shared` and `open(_:options:completionHandler:)` are unavailable to app extensions at compile time,
/// so the calls go through selectors. Main thread only.
final class ContainingAppOpener {
    private static let openWithOptions = NSSelectorFromString("openURL:options:completionHandler:")
    private static let openLegacy = NSSelectorFromString("openURL:")
    private static let sharedApplication = NSSelectorFromString("sharedApplication")

    private typealias OpenWithOptions = @convention(c) (
        AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?
    ) -> Void
    private typealias OpenLegacy = @convention(c) (AnyObject, Selector, NSURL) -> Bool

    private weak var controller: UIInputViewController?

    init(controller: UIInputViewController) {
        self.controller = controller
    }

    /// Tries the strategies for `url` and reports every try. `completion` runs on the main thread.
    func open(_ url: URL, completion: @escaping (KeyboardOpenSequence.Outcome) -> Void) {
        let upper = KeyboardRecordLink.uppercasedScheme(url)
        KeyboardOpenSequence.run(attempt: { [weak self] strategy, form, report in
            let target = form == .lowercase ? url : upper
            guard let self, let target else {
                report(.unavailable)
                return
            }
            self.attempt(strategy, url: target) { result in
                if Thread.isMainThread {
                    report(result)
                } else {
                    DispatchQueue.main.async { report(result) }
                }
            }
        }, completion: completion)
    }

    private func attempt(_ strategy: KeyboardOpenStrategy, url: URL, report: @escaping (KeyboardOpenResult) -> Void) {
        switch strategy {
        case .extensionContext:
            guard let context = controller?.extensionContext else {
                report(.unavailable)
                return
            }
            context.open(url) { report($0 ? .success : .failure) }
        case .responderChain:
            // Only the `UIApplication` instance. `UIWindowScene` also answers `openURL:options:completionHandler:`
            // on iOS 17+, but inside an extension it forwards to an unavailable target and raises (crash on
            // 2026-10-22), so every other responder is skipped even when it answers the selector.
            guard let applicationClass = Self.applicationClass,
                  let application = ResponderChainSearch.first(from: controller as UIResponder?, next: { $0.next },
                                                               where: { $0.isKind(of: applicationClass) }) else {
                report(.unavailable)
                return
            }
            Self.callBestOpen(on: application, url: url, report: report)
        case .sharedApplication:
            guard let applicationClass = Self.applicationClass,
                  (applicationClass as AnyObject).responds(to: Self.sharedApplication),
                  let application = (applicationClass as AnyObject).value(forKey: "sharedApplication") as? NSObject,
                  application.isKind(of: applicationClass) else {
                report(.unavailable)
                return
            }
            Self.callBestOpen(on: application, url: url, report: report)
        }
    }

    private static var applicationClass: AnyClass? { NSClassFromString("UIApplication") }

    private static func callBestOpen(on application: NSObject, url: URL, report: @escaping (KeyboardOpenResult) -> Void) {
        if application.responds(to: openWithOptions) {
            callOpen(on: application, url: url, report: report)
        } else if application.responds(to: openLegacy) {
            callLegacyOpen(on: application, url: url, report: report)
        } else {
            report(.unavailable)
        }
    }

    /// `-[UIApplication openURL:options:completionHandler:]` with empty options. `perform(_:with:with:)` carries
    /// at most two arguments, so the method is called through its implementation pointer.
    private static func callOpen(on target: NSObject, url: URL, report: @escaping (KeyboardOpenResult) -> Void) {
        guard let implementation = target.method(for: openWithOptions) else {
            report(.unavailable)
            return
        }
        let function = unsafeBitCast(implementation, to: OpenWithOptions.self)
        let handler: @convention(block) (Bool) -> Void = { report($0 ? .success : .failure) }
        function(target, openWithOptions, url as NSURL, [String: Any]() as NSDictionary, handler)
    }

    /// `-[UIApplication openURL:]`, which returns a `BOOL` rather than an object, so it is not called through
    /// `perform` (which would read the `BOOL` as an object pointer).
    private static func callLegacyOpen(on target: NSObject, url: URL, report: @escaping (KeyboardOpenResult) -> Void) {
        guard let implementation = target.method(for: openLegacy) else {
            report(.unavailable)
            return
        }
        let function = unsafeBitCast(implementation, to: OpenLegacy.self)
        report(function(target, openLegacy, url as NSURL) ? .success : .failure)
    }
}
