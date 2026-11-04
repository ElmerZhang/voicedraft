import XCTest
import VoiceDraftCore
@testable import VoiceDraft

/// `take-request.json`: the keyboard's Ask anything options for the take it is about to start.
final class KeyboardTakeRequestTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("take-request-\(UUID().uuidString).json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    func testRoundTripAndClear() throws {
        let store = KeyboardTakeRequestStore(fileURL: url)
        XCTAssertNil(store.read())
        // ISO 8601 keeps whole seconds, so use a whole-second date.
        let request = KeyboardTakeRequest(mode: "ask", reference: "Reference sample",
                                          createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.write(request)
        XCTAssertEqual(store.read(), request)
        store.clear()
        XCTAssertNil(store.read())
    }

    func testMissingModeAndReferenceDecodeAsEmpty() throws {
        let id = UUID()
        try Data(#"{"id":"\#(id.uuidString)","createdAt":"2026-01-01T00:00:00Z"}"#.utf8).write(to: url)
        let request = try XCTUnwrap(KeyboardTakeRequestStore(fileURL: url).read())
        XCTAssertEqual(request.id, id)
        XCTAssertEqual(request.mode, "")
        XCTAssertEqual(request.reference, "")
    }

    func testReferenceIsTrimmedAndCapped() {
        XCTAssertEqual(KeyboardTakeRequest(mode: "ask", reference: "  spaced \n").reference, "spaced")
        let long = String(repeating: "a", count: KeyboardTakeRequest.referenceLimit + 50)
        XCTAssertEqual(KeyboardTakeRequest(mode: "ask", reference: long).reference.count, KeyboardTakeRequest.referenceLimit)
    }

    func testValidOnlyWhileFreshAndForTheMatchingTake() {
        let now = Date()
        let id = UUID()
        XCTAssertTrue(KeyboardTakeRequest(id: id, mode: "ask", createdAt: now.addingTimeInterval(-29)).isValid(for: nil, now: now))
        XCTAssertTrue(KeyboardTakeRequest(id: id, mode: "ask", createdAt: now).isValid(for: id, now: now))
        XCTAssertFalse(KeyboardTakeRequest(id: id, mode: "ask", createdAt: now.addingTimeInterval(-31)).isValid(for: nil, now: now),
                       "a request left over from an earlier attempt is ignored")
        XCTAssertFalse(KeyboardTakeRequest(id: id, mode: "ask", createdAt: now.addingTimeInterval(5)).isValid(for: nil, now: now))
        XCTAssertFalse(KeyboardTakeRequest(id: id, mode: "ask", createdAt: now).isValid(for: UUID(), now: now),
                       "a record link only accepts the request written for its own take")
    }
}

/// The keyboard presents Ask anything answers and inserts everything else.
final class KeyboardAnswerDecisionTests: XCTestCase {
    func testOnlyNonEmptyAskResultsAreAnswers() {
        XCTAssertTrue(SharedResult(text: "An answer", mode: "ask").isAnswer)
        XCTAssertFalse(SharedResult(text: "", mode: "ask").isAnswer, "an empty result still means the take finished")
        XCTAssertFalse(SharedResult(text: "Dictated", mode: "polish").isAnswer)
        XCTAssertFalse(SharedResult(text: "Translated", mode: "translate").isAnswer)
        XCTAssertFalse(SharedResult(text: "Legacy").isAnswer)
    }

    func testResumeDecisionPresentsAnswersAndInsertsOtherResults() {
        let pending = PendingTake()
        let answer = SharedResult(id: pending.id, text: "An answer", mode: "ask")
        XCTAssertEqual(KeyboardResumeDecision.decide(pending: pending, latest: answer, status: nil), .present(answer))
        let dictation = SharedResult(id: pending.id, text: "Dictated", mode: "polish")
        XCTAssertEqual(KeyboardResumeDecision.decide(pending: pending, latest: dictation, status: nil), .insert(dictation))
        let failed = SharedResult(id: pending.id, text: "", mode: "ask")
        XCTAssertEqual(KeyboardResumeDecision.decide(pending: pending, latest: failed, status: nil), .insert(failed))
    }
}

/// Reference text reaches the writing request only for Ask anything takes.
final class AskTakeConfigurationTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ask-config-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func settingsAndCredentials() throws -> (SharedSettings, InMemoryCredentialStore) {
        let settings = try IOSLocalStore(directory: directory).loadSettings()
        let credentials = InMemoryCredentialStore()
        // Placeholder strings, never sent anywhere.
        try credentials.write("placeholder-speech", account: CredentialAccount.profile(settings.speechID))
        try credentials.write("placeholder-writing", account: CredentialAccount.profile(settings.writingID))
        return (settings, credentials)
    }

    func testSelectionIsKeptOnlyForAsk() throws {
        let (settings, credentials) = try settingsAndCredentials()
        let ask = try TakeConfiguration.make(settings: settings, mode: .ask, credentials: credentials,
                                             application: "", selection: "  Reference sample  ")
        XCTAssertEqual(ask.selection, "Reference sample")
        let polish = try TakeConfiguration.make(settings: settings, mode: .polish, credentials: credentials,
                                                application: "", selection: "Reference sample")
        XCTAssertEqual(polish.selection, "")
    }

    func testWritingRequestCarriesTheReferenceAsSelectedText() throws {
        let (settings, credentials) = try settingsAndCredentials()
        let ask = try TakeConfiguration.make(settings: settings, mode: .ask, credentials: credentials,
                                             application: "", selection: "Reference sample")
        // Built only; no request is sent.
        XCTAssertEqual(try selectedText(in: ask.writingRequest(for: "What is this?")), "Reference sample")
        let polish = try TakeConfiguration.make(settings: settings, mode: .polish, credentials: credentials,
                                                application: "", selection: "Reference sample")
        XCTAssertEqual(try selectedText(in: polish.writingRequest(for: "Dictated")), "")
    }

    /// `selected_text` from the JSON object in the user message of the request body.
    private func selectedText(in request: URLRequest) throws -> String? {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first { $0["role"] as? String == "user" }?["content"] as? String)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        return input["selected_text"] as? String
    }
}

/// The app consumes the keyboard's take request in both start paths.
@MainActor
final class AskAnythingModelTests: XCTestCase {
    private var directory: URL!
    private var credentials: InMemoryCredentialStore!
    private var audio: SilentAudioCapture!
    private let keepAlive = SilentStandbyKeepAlive()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)")
        credentials = InMemoryCredentialStore()
        audio = SilentAudioCapture()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private var resultStore: SharedResultStore { SharedResultStore(fileURL: directory.appendingPathComponent("result.json")) }
    private var statusStore: AppStatusStore { AppStatusStore(fileURL: directory.appendingPathComponent("status.json")) }
    private var pendingStore: PendingTakeStore { PendingTakeStore(fileURL: directory.appendingPathComponent("pending.json")) }
    private var requestStore: KeyboardTakeRequestStore {
        KeyboardTakeRequestStore(fileURL: directory.appendingPathComponent("take-request.json"))
    }

    private func makeModel() throws -> AppModel {
        let store = try IOSLocalStore(directory: directory)
        let settings = try store.loadSettings()
        try store.saveSettings(settings)
        // Placeholder strings, never sent anywhere.
        try credentials.write("placeholder-speech", account: CredentialAccount.profile(settings.speechID))
        try credentials.write("placeholder-writing", account: CredentialAccount.profile(settings.writingID))
        return AppModel(dependencies: .init(
            store: store, credentials: credentials, statusStore: statusStore, resultStore: resultStore,
            presenceStore: KeyboardPresenceStore(fileURL: directory.appendingPathComponent("presence.json")),
            audio: audio, keepAlive: keepAlive, usageLog: IOSUsageLog(directory: nil), post: { _ in }, observeKeyboard: false,
            pendingTakeStore: pendingStore, takeRequestStore: requestStore))
    }

    func testRecordLinkWithMatchingRequestRunsAskAndConsumesTheRequest() async throws {
        let model = try makeModel()
        XCTAssertEqual(model.mode, .polish)
        let take = PendingTake()
        try pendingStore.write(take)
        try requestStore.write(KeyboardTakeRequest(id: take.id, mode: "ask", reference: "Reference sample"))
        model.receiveRecordLink(try XCTUnwrap(KeyboardRecordLink.url(for: take)))
        XCTAssertEqual(model.takeState, .recording)
        XCTAssertNil(requestStore.read(), "the request is deleted when the take starts")
        XCTAssertEqual(model.resultMode, .ask)
        XCTAssertFalse(model.showsAnswer, "no answer yet while the question is recorded")
        XCTAssertEqual(model.mode, .polish, "the request applies to this take only")
        model.cancelTake()
        XCTAssertEqual(resultStore.read()?.id, take.id)
        XCTAssertEqual(resultStore.read()?.mode, "ask")
        model.endListening()
    }

    func testRecordLinkIgnoresARequestForAnotherTake() async throws {
        let model = try makeModel()
        let take = PendingTake()
        try requestStore.write(KeyboardTakeRequest(id: UUID(), mode: "ask", reference: "Reference sample"))
        model.receiveRecordLink(try XCTUnwrap(KeyboardRecordLink.url(for: take)))
        XCTAssertNil(requestStore.read())
        XCTAssertEqual(model.resultMode, .polish)
        model.cancelTake()
        XCTAssertEqual(resultStore.read()?.mode, "polish")
        model.endListening()
    }

    func testStandbyStartUsesAFreshRequestAndIgnoresAStaleOne() async throws {
        let model = try makeModel()
        await model.setListening(true)
        defer { model.endListening() }

        try requestStore.write(KeyboardTakeRequest(mode: "ask", reference: "Old", createdAt: Date().addingTimeInterval(-60)))
        model.keyboardRequestedStart()
        XCTAssertEqual(model.takeState, .recording)
        XCTAssertNil(requestStore.read(), "a stale request is deleted too")
        XCTAssertEqual(model.resultMode, .polish)
        model.cancelTake()

        let request = KeyboardTakeRequest(mode: "ask", reference: "Reference sample")
        try requestStore.write(request)
        model.keyboardRequestedStart()
        XCTAssertEqual(model.takeState, .recording)
        XCTAssertNil(requestStore.read())
        XCTAssertEqual(model.resultMode, .ask)
        XCTAssertEqual(statusStore.read()?.takeID, request.id, "the take uses the request's id")
        model.cancelTake()
        XCTAssertEqual(resultStore.read()?.mode, "ask")
    }

    func testRequestIsDeletedEvenWhenNoTakeCanStart() throws {
        let model = try makeModel()
        try requestStore.write(KeyboardTakeRequest(mode: "ask"))
        model.keyboardRequestedStart() // Not on standby.
        XCTAssertEqual(model.takeState, .idle)
        XCTAssertNil(requestStore.read())
    }

    func testLaunchDeletesAStaleRequestButKeepsOneForAnIncomingRecordLink() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try requestStore.write(KeyboardTakeRequest(mode: "ask", reference: "Old", createdAt: Date().addingTimeInterval(-60)))
        _ = try makeModel()
        XCTAssertNil(requestStore.read(), "a start the app never handled must not leave the selection behind")

        let fresh = KeyboardTakeRequest(mode: "ask", reference: "Reference sample")
        try requestStore.write(fresh)
        let model = try makeModel()
        XCTAssertEqual(requestStore.read()?.id, fresh.id, "a cold launch handles its record link after loading")
        model.sceneBecameActive()
        XCTAssertNotNil(requestStore.read())
    }

    func testAskCardTracksTheTakeMode() throws {
        let model = try makeModel()
        model.setMode(.ask)
        model.askReference = "Reference sample"
        XCTAssertTrue(model.startTake())
        XCTAssertEqual(model.resultMode, .ask)
        XCTAssertFalse(model.showsAnswer, "the card shows the question, not an answer, while recording")
        model.cancelTake()
        model.setMode(.polish)
        XCTAssertTrue(model.startTake())
        XCTAssertFalse(model.showsAnswer)
        model.cancelTake()
        XCTAssertEqual(model.askReference, "Reference sample", "the reference stays until the user edits it")
    }
}

final class HistoryFilterTests: XCTestCase {
    func testFiltersMatchCoreListing() {
        let history = [HistoryEntry(mode: .polish, original: "a", result: "A", application: "VoiceDraft", duration: 1),
                       HistoryEntry(mode: .ask, original: "Question?", result: "Answer.", application: "VoiceDraft", duration: 1),
                       HistoryEntry(mode: .translate, original: "b", result: "B", application: "VoiceDraft", duration: 1)]
        XCTAssertEqual(HistoryFilter.all.groups(history).flatMap(\.entries).count, 3)
        XCTAssertEqual(Set(HistoryFilter.dictations.groups(history).flatMap(\.entries).map(\.mode)), [.polish, .translate])
        XCTAssertEqual(HistoryFilter.ask.groups(history).flatMap(\.entries).map(\.mode), [.ask])
        XCTAssertEqual(HistoryFilter.allCases.map(\.rawValue), [0, 1, 2])
        XCTAssertEqual(HistoryFilter.dayTitle(Date()), AppText.t("Today"))
    }
}
