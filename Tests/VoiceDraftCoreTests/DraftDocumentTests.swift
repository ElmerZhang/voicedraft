import XCTest
@testable import VoiceDraftCore

/// The Draft window's pure text rules: where a dictated passage goes, and take tracking.
final class DraftDocumentTests: XCTestCase {
    /// Applies the insertion for a caret marked `|` (or a selection marked `[...]`) and
    /// returns the new text with the caret marked `|`.
    private func insert(_ passage: String, _ marked: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        var text = marked
        var selection = NSRange(location: 0, length: 0)
        if let open = text.range(of: "["), let close = text.range(of: "]") {
            let start = text.utf16.distance(from: text.startIndex, to: open.lowerBound)
            let length = text.utf16.distance(from: open.upperBound, to: close.lowerBound)
            text.removeSubrange(close); text.removeSubrange(open)
            selection = NSRange(location: start, length: length)
        } else if let caret = text.range(of: "|") {
            selection = NSRange(location: text.utf16.distance(from: text.startIndex, to: caret.lowerBound), length: 0)
            text.removeSubrange(caret)
        } else { XCTFail("No caret", file: file, line: line) }
        let insertion = DraftText.insertion(for: passage, into: text, selection: selection)
        let updated = (text as NSString).replacingCharacters(in: insertion.replacementRange, with: insertion.replacement)
        XCTAssertEqual((updated as NSString).substring(with: insertion.textRange), passage.trimmingCharacters(in: .newlines),
                       "textRange covers the passage", file: file, line: line)
        return (updated as NSString).replacingCharacters(in: NSRange(location: insertion.caretAfter, length: 0), with: "|")
    }

    func testSelectionIsReplaced() {
        XCTAssertEqual(insert("第三段", "第一段\n\n[第二段]\n\n结尾"), "第一段\n\n第三段|\n\n结尾")
        XCTAssertEqual(insert("better", "a [good] plan"), "a better| plan")
    }

    func testEmptyDocumentAndDocumentEdges() {
        XCTAssertEqual(insert("第一段。", "|"), "第一段。|")
        // Start of the document: a blank line after, none before.
        XCTAssertEqual(insert("开头。", "|已有内容。"), "开头。|\n\n已有内容。")
        // End of the document: a blank line before, none after.
        XCTAssertEqual(insert("结尾。", "已有内容。|"), "已有内容。\n\n结尾。|")
        // Trailing empty lines at the end are folded into the separator, never left at the edge.
        XCTAssertEqual(insert("结尾。", "已有内容。\n\n\n|"), "已有内容。\n\n结尾。|")
        XCTAssertEqual(insert("开头。", "|\n\n已有内容。"), "开头。|\n\n已有内容。")
    }

    func testEmptyLineBetweenParagraphs() {
        XCTAssertEqual(insert("中间。", "第一段。\n|\n第二段。"), "第一段。\n\n中间。|\n\n第二段。")
        // Several blank lines collapse: never two blank lines in a row.
        XCTAssertEqual(insert("中间。", "第一段。\n\n\n|\n\n\n第二段。"), "第一段。\n\n中间。|\n\n第二段。")
    }

    func testStartAndEndOfParagraph() {
        // End of a paragraph followed by a single line break.
        XCTAssertEqual(insert("新段。", "第一段。|\n第二段。"), "第一段。\n\n新段。|\n\n第二段。")
        // End of a paragraph followed by an existing blank line.
        XCTAssertEqual(insert("新段。", "第一段。|\n\n第二段。"), "第一段。\n\n新段。|\n\n第二段。")
        // Start of a paragraph after a single line break and after a blank line.
        XCTAssertEqual(insert("新段。", "第一段。\n|第二段。"), "第一段。\n\n新段。|\n\n第二段。")
        XCTAssertEqual(insert("新段。", "第一段。\n\n|第二段。"), "第一段。\n\n新段。|\n\n第二段。")
    }

    func testInlineInsertion() {
        // Chinese: no spaces added.
        XCTAssertEqual(insert("非常", "这个功能|好用。"), "这个功能非常|好用。")
        // Latin letters or digits on both sides of a boundary get one ASCII space.
        XCTAssertEqual(insert("really", "This is|good."), "This is really| good.")
        XCTAssertEqual(insert("v2", "Ship|today"), "Ship v2| today")
        // An existing space or punctuation means no added space on that side.
        XCTAssertEqual(insert("really", "This is |good."), "This is really| good.")
        XCTAssertEqual(insert("really", "This is| good."), "This is really| good.")
        XCTAssertEqual(insert("really", "This is,|good."), "This is,really| good.")
        // Mixed: Chinese on one side, Latin on the other.
        XCTAssertEqual(insert("API", "调用|接口"), "调用API|接口")
    }

    func testPassageEdgeLineBreaksAreDropped() {
        XCTAssertEqual(insert("\n新段。\n", "第一段。|"), "第一段。\n\n新段。|")
        // A passage the model split into two paragraphs keeps its inner blank line.
        XCTAssertEqual(insert("甲。\n\n乙。", "|"), "甲。\n\n乙。|")
    }

    func testUTF16OffsetsWithEmoji() {
        XCTAssertEqual(insert("好", "😀|😀"), "😀好|😀")
        XCTAssertEqual(insert("新段。", "😀😀|"), "😀😀\n\n新段。|")
    }

    func testLastTakeIsIntact() {
        var document = DraftDocument(text: "第一段。\n\n第二段。")
        XCTAssertFalse(DraftDocument.lastTakeIsIntact(document), "no take")
        document.takes = [DraftTake(range: NSRange(location: 6, length: 4), transcript: "嗯第二段", result: "第二段。", kind: .dictation)]
        XCTAssertTrue(DraftDocument.lastTakeIsIntact(document))
        document.text = "第一段。\n\n第二段！"
        XCTAssertFalse(DraftDocument.lastTakeIsIntact(document), "edited inside the take")
        document.text = "第一段。"
        XCTAssertFalse(DraftDocument.lastTakeIsIntact(document), "range beyond the text")
        document.text = "第一段。\n\n第二段。"
        document.takes[0].location = NSNotFound
        XCTAssertFalse(DraftDocument.lastTakeIsIntact(document), "invalidated by an overlapping edit")
    }

    func testTakeRangeFollowsEdits() {
        let take = DraftTake(range: NSRange(location: 10, length: 5), transcript: "t", result: "rrrrr", kind: .dictation)
        // Insertion of 3 characters before: shifted.
        XCTAssertEqual(take.shifted(byEditIn: NSRange(location: 2, length: 3), changeInLength: 3).range, NSRange(location: 13, length: 5))
        // Deletion of 4 characters before (post-edit range is empty at 2).
        XCTAssertEqual(take.shifted(byEditIn: NSRange(location: 2, length: 0), changeInLength: -4).range, NSRange(location: 6, length: 5))
        // Insertion exactly at the take's start shifts it; at its end leaves it.
        XCTAssertEqual(take.shifted(byEditIn: NSRange(location: 10, length: 2), changeInLength: 2).range, NSRange(location: 12, length: 5))
        XCTAssertEqual(take.shifted(byEditIn: NSRange(location: 15, length: 2), changeInLength: 2).range, NSRange(location: 10, length: 5))
        // Anything after: unchanged.
        XCTAssertEqual(take.shifted(byEditIn: NSRange(location: 20, length: 0), changeInLength: -3).range, NSRange(location: 10, length: 5))
        // Overlap invalidates.
        XCTAssertEqual(take.shifted(byEditIn: NSRange(location: 12, length: 1), changeInLength: 1).location, NSNotFound)
        XCTAssertEqual(take.shifted(byEditIn: NSRange(location: 8, length: 0), changeInLength: -4).location, NSNotFound)
    }

    func testTitle() {
        XCTAssertNil(DraftDocument(text: "\n  \n").title)
        XCTAssertEqual(DraftDocument(text: "\n  草稿窗口的设计  \n第二行").title, "草稿窗口的设计")
        let long = String(repeating: "长", count: 80)
        XCTAssertEqual(DraftDocument(text: long).title, String(repeating: "长", count: DraftDocument.titleLimit) + "…")
        XCTAssertFalse(DraftDocument().displayTitle.isEmpty)
    }

    func testRepolishOnlyForTextTakes() {
        XCTAssertTrue(DraftTake(range: NSRange(), transcript: "", result: "", kind: .dictation).canRepolish)
        XCTAssertTrue(DraftTake(range: NSRange(), transcript: "", result: "", kind: .repolish).canRepolish)
        XCTAssertTrue(DraftTake(range: NSRange(), transcript: "", result: "", kind: .styleApply).canRepolish)
        XCTAssertFalse(DraftTake(range: NSRange(), transcript: "", result: "", kind: .selectionEdit).canRepolish)
        XCTAssertFalse(DraftTake(range: NSRange(), transcript: "", result: "", kind: .wholeDraftEdit).canRepolish)
    }

    func testSurroundingsAreBounded() {
        let text = String(repeating: "前", count: 2000) + "|" + String(repeating: "后", count: 800)
        let caret = NSRange(location: 2000, length: 0)
        let around = DraftText.surroundings(of: caret, in: text)
        XCTAssertEqual(around.before, String(repeating: "前", count: 1500))
        XCTAssertEqual(around.after, "|" + String(repeating: "后", count: 499))
        XCTAssertEqual(DraftWritingContext.passage(at: NSRange(location: 2, length: 1), in: "ab[c]d"), .passage(before: "ab", after: "c]d"))
    }
}

final class FileDraftStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("draft-store-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripListOrderAndDelete() throws {
        let store = FileDraftStore(directory: directory)
        XCTAssertEqual(try store.list(), [], "a missing directory is an empty list")
        var older = DraftDocument(createdAt: Date(timeIntervalSince1970: 1_000), text: "旧草稿")
        older.takes = [DraftTake(id: UUID(), date: Date(timeIntervalSince1970: 1_000), range: NSRange(location: 0, length: 3),
                                 transcript: "嗯旧草稿", result: "旧草稿", historyID: UUID(), kind: .dictation, mode: .polish)]
        var newer = DraftDocument(createdAt: Date(timeIntervalSince1970: 2_000), text: "新草稿")
        newer.updatedAt = Date(timeIntervalSince1970: 3_000)
        try store.save(older); try store.save(newer)
        XCTAssertEqual(try store.list(), [newer, older])
        older.updatedAt = Date(timeIntervalSince1970: 4_000); older.text += "，改过"
        try store.save(older)
        XCTAssertEqual(try store.list().map(\.id), [older.id, newer.id], "most recently updated first")
        XCTAssertEqual(try store.list().first, older, "round trip keeps text, takes and dates")
        try store.delete(older.id)
        XCTAssertEqual(try store.list(), [newer])
        try store.delete(older.id)   // deleting twice is harmless
    }

    func testFilesArePrivateAndUnreadableFilesAreSkipped() throws {
        let store = FileDraftStore(directory: directory)
        let draft = DraftDocument(text: "内容")
        try store.save(draft)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url(for: draft.id).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try Data("not json".utf8).write(to: directory.appendingPathComponent(UUID().uuidString + ".json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        XCTAssertEqual(try store.list(), [draft])
    }

    func testSaveIsAtomicReplacement() throws {
        let store = FileDraftStore(directory: directory)
        var draft = DraftDocument(text: String(repeating: "长", count: 10_000))
        try store.save(draft)
        draft.text = "短"
        try store.save(draft)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, [draft.id.uuidString + ".json"], "no temporary files left behind")
        XCTAssertEqual(try store.list().first?.text, "短")
    }
}
