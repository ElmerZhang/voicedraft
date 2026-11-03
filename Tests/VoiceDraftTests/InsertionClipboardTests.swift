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

    private func writeProvided(_ text: String, to board: NSPasteboard) -> InsertionClipboardProvider {
        let provider = InsertionClipboardProvider(text: text)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.string]))
        XCTAssertTrue(item.setData(Data(), forType: .init("org.nspasteboard.TransientType")))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        return provider
    }

    func testProviderSuppliesTextLazilyAndRecordsTheRequest() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let provider = writeProvided("dictated", to: board)
        XCTAssertFalse(provider.requested)
        XCTAssertEqual(board.string(forType: .string), "dictated")
        XCTAssertTrue(provider.requested)
    }

    func testWaitForFirstRequestResumesAfterARead() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let provider = writeProvided("dictated", to: board)
        let resumed = expectation(description: "Waiter resumes")
        let waiter = Task { await provider.waitForFirstRequest(); resumed.fulfill() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(provider.requested)
        XCTAssertEqual(board.string(forType: .string), "dictated")
        await fulfillment(of: [resumed], timeout: 1)
        await waiter.value
        // After the first request a later wait returns immediately.
        await provider.waitForFirstRequest()
    }

    func testStopWaitingEndsAWaitWithoutARequest() async {
        let provider = InsertionClipboardProvider(text: "dictated")
        let waiter = Task { await provider.waitForFirstRequest() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        provider.stopWaiting()
        await waiter.value
        XCTAssertFalse(provider.requested)
    }

    func testRestoreAfterConsumptionHonorsTheRecordedGeneration() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        guard let snapshot = await InsertionClipboardReader().read(name: board.name) else { return XCTFail("No snapshot") }
        await MainActor.run {
            let provider = writeProvided("dictated", to: board)
            let generation = board.changeCount
            XCTAssertEqual(board.string(forType: .string), "dictated")
            XCTAssertTrue(provider.requested)
            XCTAssertEqual(board.changeCount, generation, "a lazy read must not bump the generation")
            var released = 0
            let restoration = InsertionClipboardRestoration(previous: snapshot, board: board, generation: generation) { released += 1 }
            restoration.finish()
            XCTAssertEqual(board.string(forType: .string), "original")
            restoration.finish()
            XCTAssertEqual(released, 1, "restore and lease release run once")

            _ = writeProvided("dictated", to: board)
            let stale = board.changeCount
            board.clearContents(); board.setString("new user copy", forType: .string)
            let late = InsertionClipboardRestoration(previous: snapshot, board: board, generation: stale) {}
            late.finish()
            XCTAssertEqual(board.string(forType: .string), "new user copy")
        }
    }
}
