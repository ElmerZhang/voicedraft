import XCTest
@testable import VoiceDraftCore

final class TextInsertionReceiptTests: XCTestCase {
    func testAcknowledgedButIgnoredWriteDoesNotConfirmInsertion() {
        let receipt = TextInsertionReceipt(value: "", range: NSRange(location: 0, length: 0), replacement: "Hello")
        XCTAssertFalse(receipt.confirms(value: "", range: NSRange(location: 0, length: 0)))
        XCTAssertFalse(receipt.confirms(value: "", range: NSRange(location: 5, length: 0)))
        XCTAssertTrue(receipt.confirms(value: "Hello", range: NSRange(location: 5, length: 0)))
    }

    func testPasteReplacesOnlySelectedTextAndUsesUTF16Offsets() {
        let receipt = TextInsertionReceipt(value: "Hi 👋，周二见！", range: NSRange(location: 6, length: 2), replacement: "周四下午 🕒")
        XCTAssertTrue(receipt.confirms(value: "Hi 👋，周四下午 🕒见！", range: nil))
        XCTAssertFalse(receipt.confirms(value: "Hi 👋，周二见！", range: nil))
        XCTAssertFalse(receipt.confirms(value: "周四下午 🕒", range: nil))
    }

    func testRichEditorCanConfirmWithCaretWhenValueIsUnavailable() {
        let receipt = TextInsertionReceipt(value: nil, range: NSRange(location: 4, length: 2), replacement: "你好 👋")
        XCTAssertFalse(receipt.confirms(value: nil, range: NSRange(location: 4, length: 2)))
        XCTAssertFalse(receipt.confirms(value: nil, range: NSRange(location: 8, length: 0)))
        XCTAssertTrue(receipt.confirms(value: nil, range: NSRange(location: 9, length: 0)))
    }

    func testIdenticalReplacementNeedsSelectionCollapse() {
        let receipt = TextInsertionReceipt(value: "hello", range: NSRange(location: 0, length: 5), replacement: "hello")
        XCTAssertFalse(receipt.confirms(value: "hello", range: NSRange(location: 0, length: 5)))
        XCTAssertTrue(receipt.confirms(value: "hello", range: NSRange(location: 5, length: 0)))
    }

    func testUnknownAndInvalidRangesCannotProduceFalseSuccess() {
        for range in [nil, NSRange(location: NSNotFound, length: 0), NSRange(location: 10, length: 0),
                      NSRange(location: 0, length: Int.max), NSRange(location: -1, length: 0)] {
            let receipt = TextInsertionReceipt(value: "", range: range, replacement: "Hello")
            XCTAssertFalse(receipt.confirms(value: "Hello", range: NSRange(location: 5, length: 0)))
        }
    }
}
