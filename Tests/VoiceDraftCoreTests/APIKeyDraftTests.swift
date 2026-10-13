import XCTest
@testable import VoiceDraftCore

final class APIKeyDraftTests: XCTestCase {
    func testSavedKeyIsIndicatedWithoutPuttingItInTheEditableValue() {
        let draft = APIKeyDraft(hasSavedKey: true)
        XCTAssertTrue(draft.showsSavedKey)
        XCTAssertEqual(draft.replacement, "")
        XCTAssertNil(draft.credentialUpdate)
        XCTAssertEqual(draft.keyForRequest { "test-only-stored-key" }, "test-only-stored-key")
    }

    func testReplacementUsesNewKeyAndClearingItPreservesSavedKey() {
        var draft = APIKeyDraft(hasSavedKey: true)
        draft.replacement = " test-only-new-key\r\n"
        XCTAssertFalse(draft.showsSavedKey)
        XCTAssertEqual(draft.credentialUpdate, "test-only-new-key")
        XCTAssertEqual(draft.keyForRequest {
            XCTFail("A replacement must not read the stored secret")
            return "unused"
        }, "test-only-new-key")
        draft.replacement = ""
        XCTAssertTrue(draft.showsSavedKey)
        XCTAssertNil(draft.credentialUpdate)
        draft.replacement = " \r\n"
        XCTAssertNil(draft.credentialUpdate, "Whitespace-only input must not delete a saved key")
    }

    func testRemovalIsExplicitAndCanBeCancelled() {
        var draft = APIKeyDraft(hasSavedKey: true)
        draft.removeSavedKey = true
        XCTAssertFalse(draft.showsSavedKey)
        XCTAssertEqual(draft.credentialUpdate, "")
        XCTAssertEqual(draft.keyForRequest {
            XCTFail("An explicitly removed key must not be used for a test request")
            return "unused"
        }, "")
        draft.removeSavedKey = false
        XCTAssertTrue(draft.showsSavedKey)
        XCTAssertNil(draft.credentialUpdate)
    }

    func testMissingOrUnreadableKeyIsNotRepresentedAsSaved() {
        let draft = APIKeyDraft(hasSavedKey: false)
        XCTAssertFalse(draft.showsSavedKey)
        XCTAssertNil(draft.credentialUpdate)
        XCTAssertEqual(draft.keyForRequest { "" }, "")
        XCTAssertThrowsError(try draft.keyForRequest { throw VoiceDraftError.message("Test keychain error") })
    }
}
