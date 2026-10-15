import XCTest
@testable import VoiceDraftCore

final class FnChordTests: XCTestCase {
    private typealias Event = FnChordTracker.Event
    private let fn = ShortcutBinding.fnKeyCode
    private let shift: UInt32 = 1, control: UInt32 = 2, command: UInt32 = 8

    func testValidateAcceptsFnChordsAndKeepsNormalKeyRules() throws {
        try ShortcutBinding.validate([
            .init(.dictate, keyCode: fn, modifiers: 0),
            .init(.translate, keyCode: fn, modifiers: shift),
            .init(.edit, keyCode: fn, modifiers: control | shift)
        ])
        try ShortcutBinding.validate(ShortcutBinding.defaults)
        XCTAssertThrowsError(try ShortcutBinding.validate([.init(.dictate, keyCode: 0, modifiers: shift)]))
        XCTAssertThrowsError(try ShortcutBinding.validate([.init(.dictate, keyCode: fn, modifiers: shift), .init(.translate, keyCode: fn, modifiers: shift)]))
        XCTAssertThrowsError(try ShortcutBinding.validate([.init(.dictate, keyCode: fn, modifiers: 16)]))
        // A disabled duplicate does not collide.
        try ShortcutBinding.validate([.init(.dictate, keyCode: fn, modifiers: shift), .init(.translate, keyCode: fn, modifiers: shift, enabled: false)])
    }

    func testProblemNamesTheConflictingActionWithoutSaving() {
        let bindings = [ShortcutBinding(.dictate, keyCode: fn, modifiers: 0), .init(.translate, keyCode: 17, modifiers: 6)]
        XCTAssertEqual(ShortcutBinding.problem(with: .init(.translate, keyCode: fn, modifiers: 0), in: bindings), .conflict(.dictate))
        XCTAssertEqual(ShortcutBinding.problem(with: .init(.translate, keyCode: 0, modifiers: shift), in: bindings), .notAllowed)
        XCTAssertNil(ShortcutBinding.problem(with: .init(.translate, keyCode: fn, modifiers: shift), in: bindings))
        XCTAssertNil(ShortcutBinding.problem(with: .init(.translate, keyCode: fn, modifiers: 0, enabled: false), in: bindings))
        // Re-recording the same keys for the same action is not a conflict.
        XCTAssertNil(ShortcutBinding.problem(with: .init(.translate, keyCode: 17, modifiers: 6), in: bindings))
    }

    func testKeyLabels() {
        XCTAssertEqual(ShortcutBinding(.translate, keyCode: fn, modifiers: shift).keyLabel, "⇧Fn")
        XCTAssertEqual(ShortcutBinding(.translate, keyCode: fn, modifiers: control | shift).keyLabel, "⌃⇧Fn")
        XCTAssertEqual(ShortcutBinding(.dictate, keyCode: 49, modifiers: 6).keyLabel, "⌃⌥Space")
        XCTAssertEqual(ShortcutBinding(.dictate, keyCode: fn, modifiers: 0).keyLabel, "Fn")
        XCTAssertEqual(ShortcutBinding(.dictate, keyCode: fn, modifiers: 0, enabled: false).keyLabel, "Fn")
    }

    private var both: [ShortcutBinding] {
        [.init(.dictate, keyCode: fn, modifiers: 0), .init(.translate, keyCode: fn, modifiers: shift), .init(.edit, keyCode: 14, modifiers: 6)]
    }
    private var chordOnly: [ShortcutBinding] {
        [.init(.dictate, keyCode: 49, modifiers: 6), .init(.translate, keyCode: fn, modifiers: shift)]
    }

    func testShiftThenFnSelectsTheChordEvenWithFnAloneBound() {
        var tracker = FnChordTracker()
        XCTAssertEqual(tracker.observe(fnHeld: false, modifiers: shift, bindings: both), [])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: both), [Event(.translate, down: true)])
        XCTAssertEqual(tracker.observe(fnHeld: false, modifiers: shift, bindings: both), [Event(.translate, down: false)])
        XCTAssertEqual(tracker.observe(fnHeld: false, modifiers: 0, bindings: both), [])
        XCTAssertNil(tracker.active)
    }

    func testFnThenShiftKeepsFnAloneWhenItIsBound() {
        var tracker = FnChordTracker()
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: both), [Event(.dictate, down: true)])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: both), [])
        XCTAssertEqual(tracker.active, .dictate)
        XCTAssertEqual(tracker.observe(fnHeld: false, modifiers: shift, bindings: both), [Event(.dictate, down: false)])
    }

    func testFnThenShiftSelectsTheChordWhenFnAloneIsNotBound() {
        var tracker = FnChordTracker()
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: chordOnly), [])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: chordOnly), [Event(.translate, down: true)])
        XCTAssertEqual(tracker.observe(fnHeld: false, modifiers: shift, bindings: chordOnly), [Event(.translate, down: false)])
    }

    func testReleasingShiftMidChordEndsItWithoutStartingFnAlone() {
        var tracker = FnChordTracker()
        _ = tracker.observe(fnHeld: false, modifiers: shift, bindings: both)
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: both), [Event(.translate, down: true)])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: both), [Event(.translate, down: false)])
        XCTAssertFalse(tracker.armed)
        // Pressing Shift again while Fn is still held does not re-activate either.
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: both), [])
        XCTAssertEqual(tracker.observe(fnHeld: false, modifiers: shift, bindings: both), [])
        XCTAssertTrue(tracker.armed)
        // Re-armed only after Fn is fully released.
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: both), [Event(.translate, down: true)])
    }

    func testReleasingFnEndsFnAlone() {
        var tracker = FnChordTracker()
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: both), [Event(.dictate, down: true)])
        XCTAssertEqual(tracker.observe(fnHeld: false, modifiers: 0, bindings: both), [Event(.dictate, down: false)])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: both), [Event(.dictate, down: true)])
    }

    func testExtraModifierWhileActiveSendsNothing() {
        var tracker = FnChordTracker()
        _ = tracker.observe(fnHeld: false, modifiers: shift, bindings: both)
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: both), [Event(.translate, down: true)])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift | command, bindings: both), [])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: both), [])
        XCTAssertEqual(tracker.active, .translate)
    }

    func testUnboundModifierSetMatchesNothing() {
        var tracker = FnChordTracker()
        XCTAssertEqual(tracker.observe(fnHeld: false, modifiers: shift | command, bindings: chordOnly), [])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift | command, bindings: chordOnly), [])
        XCTAssertNil(tracker.active)
    }

    func testDisabledFnBindingsAreIgnored() {
        var tracker = FnChordTracker()
        let bindings = [ShortcutBinding(.dictate, keyCode: fn, modifiers: 0, enabled: false)]
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: bindings), [])
    }
}
