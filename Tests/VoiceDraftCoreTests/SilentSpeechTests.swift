import XCTest
@testable import VoiceDraftCore

final class SilentSpeechTests: XCTestCase {
    func testCompletedEmptySpeechIsDistinctFromAnEmptyWritingResponse() throws {
        let emptyChat = Data(#"{"choices":[{"message":{"content":" \n"},"finish_reason":"stop"}]}"#.utf8)
        for parse in [
            { try QwenRequests.parseSpeech(emptyChat) },
            { try AudioHTTPRequests.parse(Data(#"{"output":{"text":" "}}"#.utf8)) },
            { try WhisperRequests.parse(Data(#"{"text":""}"#.utf8)) },
            { try SpeechClient.transcript(GoogleSpeech.parse(Data(#"{"results":[]}"#.utf8))) }
        ] {
            XCTAssertThrowsError(try parse()) { error in
                guard case SpeechRecognitionError.noSpeech = error else { return XCTFail("Expected silence, got \(error)") }
            }
        }
        XCTAssertThrowsError(try QwenRequests.parse(emptyChat)) { error in
            XCTAssertFalse(error is SpeechRecognitionError, "An empty writing result must remain visible as an error")
        }
    }

    func testMalformedAndFilteredSpeechAreNotSilence() {
        for json in [#"{"choices":[]}"#, #"{"choices":[{"message":{}}]}"#,
                     #"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#,
                     #"{"choices":[{"message":{"content":""},"finish_reason":"content_filter"}]}"#] {
            XCTAssertThrowsError(try QwenRequests.parseSpeech(Data(json.utf8))) { error in
                XCTAssertFalse(error is SpeechRecognitionError)
            }
        }
        XCTAssertThrowsError(try WhisperRequests.parse(Data(#"{}"#.utf8))) { XCTAssertFalse($0 is SpeechRecognitionError) }
        XCTAssertThrowsError(try AudioHTTPRequests.parse(Data(#"{}"#.utf8))) { XCTAssertFalse($0 is SpeechRecognitionError) }
    }
}
