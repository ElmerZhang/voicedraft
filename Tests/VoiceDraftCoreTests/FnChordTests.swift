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

    func testFnThenShiftPromotesTheHeldTake() {
        var tracker = FnChordTracker()
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: both), [Event(.dictate, down: true)])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: both), [.retarget(from: .dictate, to: .translate)])
        XCTAssertEqual(tracker.active, .translate)
        // Shift released just before Fn does not demote the take.
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: both), [])
        XCTAssertEqual(tracker.active, .translate)
        XCTAssertEqual(tracker.observe(fnHeld: false, modifiers: 0, bindings: both), [Event(.translate, down: false)])
        XCTAssertNil(tracker.active)
    }

    func testShiftThenFnThenReleasingShiftKeepsTranslate() {
        var tracker = FnChordTracker()
        _ = tracker.observe(fnHeld: false, modifiers: shift, bindings: both)
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: both), [Event(.translate, down: true)])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: both), [])
        XCTAssertEqual(tracker.observe(fnHeld: false, modifiers: 0, bindings: both), [Event(.translate, down: false)])
    }

    func testReleaseLandingOnAnotherBindingDoesNotRetarget() {
        var tracker = FnChordTracker()
        let three = both + [.init(.ask, keyCode: fn, modifiers: control | shift)]
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: three), [Event(.dictate, down: true)])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: control, bindings: three), [])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: control | shift, bindings: three), [.retarget(from: .dictate, to: .ask)])
        // Releasing Control leaves Fn-Shift (Translate) held: a release, so no event.
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: three), [])
        XCTAssertEqual(tracker.active, .ask)
        // A later press that completes Fn-Control-Shift again matches the current action: nothing.
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: control | shift, bindings: three), [])
        XCTAssertEqual(tracker.observe(fnHeld: false, modifiers: control | shift, bindings: three), [Event(.ask, down: false)])
    }

    func testFnThenShiftSelectsTheChordWhenFnAloneIsNotBound() {
        var tracker = FnChordTracker()
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: chordOnly), [])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: chordOnly), [Event(.translate, down: true)])
        // Releasing Shift sends nothing: the take keeps going.
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: chordOnly), [])
        XCTAssertEqual(tracker.active, .translate)
        XCTAssertEqual(tracker.observe(fnHeld: false, modifiers: 0, bindings: chordOnly), [Event(.translate, down: false)])
    }

    func testUnmatchedIntermediateChordKeepsTheCurrentAction() {
        var tracker = FnChordTracker()
        let three = both + [.init(.ask, keyCode: fn, modifiers: control | shift)]
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: three), [Event(.dictate, down: true)])
        // Fn + Command matches nothing: no event, no cancel.
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: command, bindings: three), [])
        XCTAssertEqual(tracker.active, .dictate)
        // Fn + Control alone is unbound on the way to Fn + Control + Shift.
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: control, bindings: three), [])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: control | shift, bindings: three), [.retarget(from: .dictate, to: .ask)])
        // Extra modifiers that form no binding are ignored.
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: control | shift | command, bindings: three), [])
        XCTAssertEqual(tracker.active, .ask)
        XCTAssertEqual(tracker.observe(fnHeld: false, modifiers: 0, bindings: three), [Event(.ask, down: false)])
    }

    func testRetargetToDisabledBindingSendsNothing() {
        var tracker = FnChordTracker()
        let disabled = [ShortcutBinding(.dictate, keyCode: fn, modifiers: 0), .init(.translate, keyCode: fn, modifiers: shift, enabled: false)]
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: disabled), [Event(.dictate, down: true)])
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: disabled), [])
        XCTAssertEqual(tracker.active, .dictate)
    }

    func testRearmsOnlyAfterFnIsReleased() {
        var tracker = FnChordTracker()
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: both), [Event(.dictate, down: true)])
        // The active binding stops being bound while Fn is held: released and disarmed.
        let translateOnly = [ShortcutBinding(.translate, keyCode: fn, modifiers: shift)]
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: 0, bindings: translateOnly), [Event(.dictate, down: false)])
        XCTAssertFalse(tracker.armed)
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: translateOnly), [])
        XCTAssertEqual(tracker.observe(fnHeld: false, modifiers: shift, bindings: translateOnly), [])
        XCTAssertTrue(tracker.armed)
        XCTAssertEqual(tracker.observe(fnHeld: true, modifiers: shift, bindings: translateOnly), [Event(.translate, down: true)])
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

    func testRecordingModeMapsActionsLikeTakeStart() {
        XCTAssertEqual(ShortcutAction.dictate.recordingMode, .polish)
        XCTAssertEqual(ShortcutAction.translate.recordingMode, .translate)
        XCTAssertEqual(ShortcutAction.edit.recordingMode, .edit)
        XCTAssertEqual(ShortcutAction.ask.recordingMode, .ask)
        XCTAssertNil(ShortcutAction.styleSelection.recordingMode)
        XCTAssertNil(ShortcutAction.insertLast.recordingMode)
    }

    func testRetargetPolicyMirrorsTakeStartChecks() {
        XCTAssertNil(TakeRetargetPolicy.problem(to: .translate, selection: "", writingKey: "k"))
        XCTAssertNil(TakeRetargetPolicy.problem(to: .ask, selection: "", writingKey: "k"))
        XCTAssertNil(TakeRetargetPolicy.problem(to: .edit, selection: "text", writingKey: "k"))
        XCTAssertEqual(TakeRetargetPolicy.problem(to: .edit, selection: "", writingKey: "k"), .needsSelection)
        XCTAssertEqual(TakeRetargetPolicy.problem(to: .dictate, selection: "", writingKey: ""), .needsWritingKey)
        XCTAssertEqual(TakeRetargetPolicy.problem(to: .insertLast, selection: "", writingKey: "k"), .notRecording)
        XCTAssertEqual(TakeRetargetPolicy.problem(to: .styleSelection, selection: "x", writingKey: "k"), .notRecording)
    }
}
