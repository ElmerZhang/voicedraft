import AppKit
import XCTest
@testable import VoiceDraft

final class InsertionClipboardTests: XCTestCase {
    func testAllFormatsRestoreButNewUserCopyWins() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("com.voicedraft.test")
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data([0, 1, 2]), forType: custom)
        board.writeObjects([item])
        let snapshot = await InsertionClipboardReader().read(name: board.name)
        XCTAssertNotNil(snapshot)
        await MainActor.run {
            board.clearContents(); board.setString("temporary", forType: .string)
            snapshot?.restore(board, ifGeneration: board.changeCount)
            XCTAssertEqual(board.string(forType: .string), "original")
            XCTAssertEqual(board.data(forType: custom), Data([0, 1, 2]))
            board.clearContents(); board.setString("temporary", forType: .string)
            let generation = board.changeCount
            board.clearContents(); board.setString("new user copy", forType: .string)
            snapshot?.restore(board, ifGeneration: generation)
            XCTAssertEqual(board.string(forType: .string), "new user copy")
        }
    }

    func testOversizedSnapshotDoesNotTouchClipboard() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(Data(repeating: 1, count: 128), forType: .init("com.voicedraft.test"))
        let generation = board.changeCount
        let snapshot = await InsertionClipboardReader().read(name: board.name, maximumBytes: 127)
        XCTAssertNil(snapshot)
        XCTAssertEqual(board.changeCount, generation)
    }

    func testTimedOutProviderDoesNotAccumulateWorkers() async {
        let reader = InsertionClipboardReader()
        let release = DispatchSemaphore(value: 0)
        let exited = expectation(description: "Reader exits")
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = await reader.read(timeout: 0.02) {
            release.wait(); exited.fulfill()
            return InsertionClipboardSnapshot(generation: 0, items: [])
        }
        XCTAssertNil(snapshot)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        let second = await reader.read(timeout: 0.02) { XCTFail("Must not enqueue behind blocked provider"); return nil }
        XCTAssertNil(second)
        release.signal()
        await fulfillment(of: [exited], timeout: 1)
    }
}
