import XCTest
@testable import VoiceDraftCore

/// Replays the event sequences seen by the Settings shortcut recorder.
final class ShortcutRecorderTests: XCTestCase {
    private typealias Decision = ShortcutRecorder.Decision
    private let fn = ShortcutBinding.fnKeyCode
    private let shift: UInt32 = 1

    private func flags(_ keyCode: UInt32, _ modifiers: UInt32, fn fnHeld: Bool) -> Decision {
        ShortcutRecorder.decide(eventType: .flagsChanged, keyCode: keyCode, modifiers: modifiers, fnHeld: fnHeld, isRepeat: false)
    }

    /// The sequence from the system event probe: Shift down (56), Fn down (63)
    /// with Fn and Shift flags, Fn up, Shift up.
    func testShiftThenFnRecordsShiftFnOnFnPressEdge() {
        let decisions = [flags(56, shift, fn: false), flags(fn, shift, fn: true), flags(fn, shift, fn: false), flags(56, 0, fn: false)]
        XCTAssertEqual(decisions, [.updateLiveModifiers(shift), .record(keyCode: fn, modifiers: shift), .ignore, .updateLiveModifiers(0)])
        // The recorded chord is valid for Translate next to the defaults and labels as ⇧Fn.
        let binding = ShortcutBinding(.translate, keyCode: fn, modifiers: shift)
        XCTAssertNil(ShortcutBinding.problem(with: binding, in: ShortcutBinding.defaults))
        XCTAssertEqual(binding.keyLabel, "⇧Fn")
    }

    func testFnAloneRecordsFnWithoutModifiers() {
        XCTAssertEqual([flags(fn, 0, fn: true), flags(fn, 0, fn: false)], [.record(keyCode: fn, modifiers: 0), .ignore])
    }

    func testPlainKeysRecordWithModifiersIgnoreRepeatsAndEscCancels() {
        XCTAssertEqual(flags(58, 4, fn: false), .updateLiveModifiers(4))
        XCTAssertEqual(ShortcutRecorder.decide(eventType: .keyDown, keyCode: 49, modifiers: 6, fnHeld: false, isRepeat: false), .record(keyCode: 49, modifiers: 6))
        XCTAssertEqual(ShortcutRecorder.decide(eventType: .keyDown, keyCode: 49, modifiers: 6, fnHeld: false, isRepeat: true), .ignore)
        XCTAssertEqual(ShortcutRecorder.decide(eventType: .keyDown, keyCode: 53, modifiers: 0, fnHeld: false, isRepeat: false), .cancel)
        // Bits outside the four modifiers never reach a binding.
        XCTAssertEqual(ShortcutRecorder.decide(eventType: .keyDown, keyCode: 0, modifiers: 0x16, fnHeld: false, isRepeat: false), .record(keyCode: 0, modifiers: 6))
    }
}
