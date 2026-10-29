import XCTest
@testable import TimelineCore

@MainActor
final class ImageImportQueueTests: XCTestCase {
    func testImmediateSubmitIsBlockedAndClosingDraftKeepsLateOriginal() async throws {
        let queue = ImageImportQueue()
        var continuation: CheckedContinuation<[String], Error>?
        var persisted: [String] = []
        queue.start({ try await withCheckedThrowingContinuation { continuation = $0 } }, append: { persisted += $0 })
        XCTAssertThrowsError(try queue.requireReady())
        while continuation == nil { await Task.yield() }
        // UI 已关闭，写回目标仍是原草稿。
        continuation?.resume(returning: ["original.heic"])
        while queue.pending > 0 { await Task.yield() }
        XCTAssertEqual(persisted, ["original.heic"])
        XCTAssertNoThrow(try queue.requireReady())
    }

    func testDiscardCannotAttachLateImageToReplacementDraft() async {
        let queue = ImageImportQueue()
        var continuation: CheckedContinuation<[String], Error>?
        var images: [String] = []
        queue.start({ try await withCheckedThrowingContinuation { continuation = $0 } }, append: { images += $0 })
        while continuation == nil { await Task.yield() }
        queue.invalidate()
        queue.start({ ["new.png"] }, append: { images += $0 })
        continuation?.resume(returning: ["discarded.png"])
        while queue.pending > 0 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(images, ["new.png"])
        XCTAssertEqual(queue.pending, 0)
    }

    func testPartialFailureKeepsSuccessfulOriginalAndExplainsFailure() async {
        let queue = ImageImportQueue()
        var images: [String] = []
        queue.start({ ["good.png"] }, append: { images += $0 })
        queue.start({ throw CocoaError(.fileReadCorruptFile) }, append: { images += $0 })
        while queue.pending > 0 { await Task.yield() }
        XCTAssertEqual(images, ["good.png"])
        XCTAssertNotNil(queue.errorMessage)
    }
}
