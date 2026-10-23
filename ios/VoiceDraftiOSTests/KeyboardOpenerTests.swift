import XCTest
@testable import VoiceDraft

/// The keyboard's containing-app open sequence, run over simulated results, and the open-attempt store.
final class KeyboardOpenerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Runs the sequence with scripted results; an unscripted try fails the test.
    private func run(_ script: [String: KeyboardOpenResult]) -> (tried: [String], outcome: KeyboardOpenSequence.Outcome?) {
        var tried: [String] = []
        var outcome: KeyboardOpenSequence.Outcome?
        KeyboardOpenSequence.run(now: { self.now }, attempt: { strategy, form, report in
            let key = "\(strategy.rawValue).\(form.rawValue)"
            tried.append(key)
            guard let result = script[key] else {
                XCTFail("unexpected try \(key)")
                report(.unavailable)
                return
            }
            report(result)
        }, completion: { outcome = $0 })
        return (tried, outcome)
    }

    func testFirstSuccessWinsAndLaterStrategiesAreNotTried() throws {
        let (tried, outcome) = run(["ext.lowercase": .success])
        XCTAssertEqual(tried, ["ext.lowercase"])
        XCTAssertEqual(try XCTUnwrap(outcome).succeeded, .extensionContext)

        let second = run(["ext.lowercase": .unavailable, "chain.lowercase": .success])
        XCTAssertEqual(second.tried, ["ext.lowercase", "chain.lowercase"])
        XCTAssertEqual(second.outcome?.succeeded, .responderChain)
        XCTAssertEqual(KeyboardOpenStrategy.responderChain.number, 2)
        XCTAssertEqual(second.outcome?.attempts.map(\.at), [now, now])
    }

    func testUppercaseRetryOnlyAfterLowercaseFailure() {
        let (tried, outcome) = run(["ext.lowercase": .failure, "ext.uppercase": .failure,
                                    "chain.lowercase": .unavailable,
                                    "app.lowercase": .failure, "app.uppercase": .success])
        XCTAssertEqual(tried, ["ext.lowercase", "ext.uppercase", "chain.lowercase", "app.lowercase", "app.uppercase"],
                       "no upper-case retry after an unavailable strategy")
        XCTAssertEqual(outcome?.succeeded, .sharedApplication)
        XCTAssertEqual(outcome?.attempts.last?.urlForm, .uppercase)

        let upperWins = run(["ext.lowercase": .failure, "ext.uppercase": .success])
        XCTAssertEqual(upperWins.tried, ["ext.lowercase", "ext.uppercase"])
        XCTAssertEqual(upperWins.outcome?.succeeded, .extensionContext)
    }

    func testAllFailSummary() throws {
        let (_, outcome) = run(["ext.lowercase": .failure, "ext.uppercase": .failure,
                                "chain.lowercase": .unavailable, "app.lowercase": .unavailable])
        let result = try XCTUnwrap(outcome)
        XCTAssertNil(result.succeeded)
        XCTAssertEqual(KeyboardOpenSequence.summary(result.attempts), "ext=false/false · chain=none · app=none")
        let single = [KeyboardOpenAttempt(strategy: .extensionContext, urlForm: .lowercase, result: .failure, at: now),
                      KeyboardOpenAttempt(strategy: .responderChain, urlForm: .lowercase, result: .unavailable, at: now),
                      KeyboardOpenAttempt(strategy: .sharedApplication, urlForm: .lowercase, result: .failure, at: now)]
        XCTAssertEqual(KeyboardOpenSequence.summary(single), "ext=false · chain=none · app=false")
    }

    func testDuplicateReportIsIgnored() {
        var completions = 0
        KeyboardOpenSequence.run(attempt: { _, _, report in
            report(.success)
            report(.failure)
        }, completion: { _ in completions += 1 })
        XCTAssertEqual(completions, 1)
    }

    func testUppercasedSchemeKeepsTheRestOfTheLink() throws {
        let take = PendingTake()
        let link = try XCTUnwrap(KeyboardRecordLink.url(for: take))
        let upper = try XCTUnwrap(KeyboardRecordLink.uppercasedScheme(link))
        XCTAssertTrue(upper.absoluteString.hasPrefix("VoiceDraft://record?"))
        XCTAssertEqual(KeyboardRecordLink.takeID(from: upper), take.id)
    }

    func testAttemptStoreRoundTripAndCap() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("open-attempts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = KeyboardOpenAttemptStore(fileURL: url)
        XCTAssertEqual(store.read(), [])
        let first = KeyboardOpenAttempt(strategy: .responderChain, urlForm: .lowercase, result: .success, at: now)
        try store.append([first])
        XCTAssertEqual(store.read(), [first])

        let many = (0..<25).map {
            KeyboardOpenAttempt(strategy: .extensionContext, urlForm: .uppercase, result: .failure,
                                at: now.addingTimeInterval(TimeInterval($0)))
        }
        try store.append(many)
        let kept = store.read()
        XCTAssertEqual(kept.count, KeyboardOpenAttemptStore.limit)
        XCTAssertEqual(kept.last, many.last)
        XCTAssertEqual(kept.first, many[5], "the oldest records are dropped")

        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(store.read(), [])
    }

    private final class StubResponder {
        let name: String
        let isApplication: Bool
        var next: StubResponder?
        init(_ name: String, isApplication: Bool = false, next: StubResponder? = nil) {
            self.name = name
            self.isApplication = isApplication
            self.next = next
        }
    }

    func testChainSearchSkipsSceneAndFindsApplication() {
        // controller -> view -> window -> scene (answers openURL too) -> application
        let application = StubResponder("application", isApplication: true)
        let scene = StubResponder("scene", next: application)
        let controller = StubResponder("controller", next: StubResponder("view", next: StubResponder("window", next: scene)))
        var visited: [String] = []
        let found = ResponderChainSearch.first(from: controller, next: { $0.next },
                                               where: { visited.append($0.name); return $0.isApplication })
        XCTAssertTrue(found === application)
        XCTAssertEqual(visited, ["controller", "view", "window", "scene", "application"])
    }

    func testChainSearchWithoutApplicationIsNilAndStopsOnLoops() {
        let scene = StubResponder("scene")
        let controller = StubResponder("controller", next: scene)
        XCTAssertNil(ResponderChainSearch.first(from: controller, next: { $0.next }, where: { $0.isApplication }))
        XCTAssertNil(ResponderChainSearch.first(from: nil as StubResponder?, next: { $0.next }, where: { _ in true }))
        scene.next = controller
        var steps = 0
        XCTAssertNil(ResponderChainSearch.first(from: controller, limit: 10, next: { $0.next },
                                                where: { _ in steps += 1; return false }))
        XCTAssertEqual(steps, 10)
        scene.next = nil
    }
}
