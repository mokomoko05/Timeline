import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class FocusNoteDraftTests: XCTestCase {
    private func fixture() throws -> (FocusSession, JournalStore, ScheduledTask, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JournalStore(directory: directory)
        let task = try XCTUnwrap(store.addParsedTodo("Read paper #reading", on: Date()))
        let session = FocusSession()
        session.store = store
        session.start(task: task, url: nil)
        addTeardownBlock {
            session.stop(reason: "test")
            try? FileManager.default.removeItem(at: directory)
        }
        return (session, store, task, directory)
    }

    func testPendingImageMustRemainInDraftBeforeFocusNoteCanSave() async throws {
        let (session, store, _, _) = try fixture()
        let draft = FocusNoteDraft()
        draft.text = "Original attachment"
        var finish: CheckedContinuation<[String], Error>?
        draft.imageImports.start({ try await withCheckedThrowingContinuation { finish = $0 } }, append: { draft.images += $0 })
        XCTAssertFalse(draft.save(session: session))
        XCTAssertNotNil(draft.error)
        while finish == nil { await Task.yield() }
        finish?.resume(returning: ["original.png"])
        while draft.imageImports.pending > 0 { await Task.yield() }
        XCTAssertTrue(draft.save(session: session))
        XCTAssertEqual(store.allLogs().first { $0.log.text == "Original attachment" }?.log.images, ["original.png"])
    }

    func testInvalidCommandsAndNonEntryCommandsKeepTheEntireDraft() throws {
        let (session, store, task, _) = try fixture()
        let draft = FocusNoteDraft()
        for text in ["/unknown note", "/help", "/link #1", "/summary", "/filter #1"] {
            draft.text = text
            draft.images = ["draft.png"]
            draft.link = task.id
            draft.tags = ["reading"]
            draft.save(session: session)
            XCTAssertEqual(draft.text, text)
            XCTAssertEqual(draft.images, ["draft.png"])
            XCTAssertEqual(draft.link, task.id)
            XCTAssertEqual(draft.tags, ["reading"])
            XCTAssertNotNil(draft.error)
            XCTAssertTrue(store.allLogs().isEmpty)
        }
        draft.text = "Recovered note"
        draft.save(session: session)
        let entry = try XCTUnwrap(store.allLogs().first?.log)
        XCTAssertEqual(entry.text, "Recovered note")
        XCTAssertEqual(entry.images, ["draft.png"])
        XCTAssertEqual(entry.taskID, task.id)
        XCTAssertEqual(entry.tags, ["reading"])
        XCTAssertEqual(draft.text, "")
        XCTAssertTrue(draft.images.isEmpty)
        XCTAssertNil(draft.link)
        XCTAssertTrue(draft.tags.isEmpty)
        XCTAssertNil(draft.error)
    }

    func testReflectionLinksToItsTaskWhilePausedAndTreatsCommandsAsFeedbackText() throws {
        let (session, store, task, _) = try fixture()
        session.tick(now: Date().addingTimeInterval(3600))
        XCTAssertTrue(session.needsReflection)
        let draft = FocusNoteDraft()
        draft.text = "/done Read the introduction; next: methods"
        XCTAssertTrue(draft.save(session: session, reflection: true))
        let log = try XCTUnwrap(store.days.values.flatMap(\.logs).first { $0.focusEvent == .review })
        XCTAssertEqual(log.taskID, task.id)
        XCTAssertEqual(log.focusMarker, "REVIEW")
        XCTAssertEqual(log.text, "/done Read the introduction; next: methods")
        XCTAssertFalse(store.locate(task.id)!.task.completed)
        XCTAssertTrue(draft.text.isEmpty)
    }

    func testDiskFailureKeepsDraftAndRetryPersistsExactlyOneEntry() throws {
        let (session, store, task, directory) = try fixture()
        let draft = FocusNoteDraft()
        draft.text = "Keep this note"
        draft.images = ["draft.png"]
        draft.link = task.id
        draft.tags = ["reading"]
        try FileManager.default.removeItem(at: directory)
        try Data("blocking file".utf8).write(to: directory)
        draft.save(session: session)
        XCTAssertNotNil(draft.error)
        XCTAssertNotNil(draft.pendingEntryID)
        XCTAssertEqual(draft.text, "Keep this note")
        XCTAssertEqual(draft.images, ["draft.png"])
        XCTAssertEqual(draft.link, task.id)
        XCTAssertEqual(draft.tags, ["reading"])
        draft.save(session: session)
        XCTAssertEqual(store.allLogs().count, 1)
        XCTAssertEqual(draft.text, "Keep this note")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        draft.save(session: session)
        XCTAssertEqual(JournalStore(directory: directory).allLogs().count, 1)
        XCTAssertEqual(store.allLogs().first?.log.text, "Keep this note")
        XCTAssertNil(draft.error)
        XCTAssertNil(draft.pendingEntryID)
        XCTAssertTrue(draft.text.isEmpty)
        XCTAssertTrue(draft.images.isEmpty)
    }

    func testReadOnlyStoreKeepsTheDraft() throws {
        let (session, _, task, directory) = try fixture()
        let protected = directory.appendingPathComponent("protected")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        try Data("invalid JSON".utf8).write(to: protected.appendingPathComponent("journal.json"))
        session.store = JournalStore(directory: protected)
        let draft = FocusNoteDraft()
        draft.text = "Don't lose this note"
        draft.images = ["draft.png"]
        draft.link = task.id
        draft.tags = ["reading"]
        draft.save(session: session)
        XCTAssertNotNil(draft.error)
        XCTAssertEqual(draft.text, "Don't lose this note")
        XCTAssertEqual(draft.images, ["draft.png"])
        XCTAssertEqual(draft.link, task.id)
        XCTAssertEqual(draft.tags, ["reading"])
    }

    func testFailedReflectionSaveKeepsSessionAndRetriesWithoutDuplicatingFeedback() throws {
        let (session, store, task, directory) = try fixture()
        session.tick(now: Date().addingTimeInterval(3600))
        let draft = FocusNoteDraft()
        draft.text = "Finished methods; next: experiments"
        try FileManager.default.removeItem(at: directory)
        try Data("blocking file".utf8).write(to: directory)
        XCTAssertFalse(draft.save(session: session, reflection: true))
        XCTAssertNotNil(draft.pendingEntryID)
        XCTAssertTrue(session.needsReflection)
        XCTAssertFalse(draft.text.isEmpty)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(draft.save(session: session, reflection: true))
        XCTAssertEqual(store.allLogs().count, 1)
        XCTAssertEqual(JournalStore(directory: directory).allLogs().first?.log.taskID, task.id)
    }

    func testPausedNoteKeepsInlineReferenceAsTextWithoutTaskOrTags() throws {
        let (session, store, task, _) = try fixture()
        session.pause()
        let draft = FocusNoteDraft()
        draft.text = "#\(task.task.number!) unrelated thought"
        draft.link = task.id
        draft.tags = ["reading"]
        draft.save(session: session)
        let entry = try XCTUnwrap(store.allLogs().first?.log)
        XCTAssertEqual(entry.text, "#\(task.task.number!) unrelated thought")
        XCTAssertNil(entry.taskID)
        XCTAssertTrue(entry.tags.isEmpty)
        XCTAssertTrue(entry.taskTags.isEmpty)
    }

    func testLongMultilineGoalKeepsFixedPanelAndEditorSpaceForActions() throws {
        let (session, _, task, _) = try fixture()
        session.start(task: task, url: nil, goal: String(repeating: "Read and summarize this paper\n", count: 20))
        let size = NSSize(width: 340, height: 158)
        let host = NSHostingView(rootView: FocusPanelView(session: session).environment(\.locale, Locale(identifier: "en")))
        let window = QuietWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, size.width, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, size.height, accuracy: 1)
        func findEditor(_ view: NSView) -> ImagePasteTextView? {
            if let editor = view as? ImagePasteTextView { return editor }
            return view.subviews.lazy.compactMap(findEditor).first
        }
        let editor = try XCTUnwrap(findEditor(host))
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let rect = scroll.convert(scroll.bounds, to: host)
        XCTAssertTrue(host.bounds.contains(rect))
        XCTAssertEqual(scroll.bounds.height, 24, accuracy: 1, "输入区显示一行，长内容在框内滚动")
        XCTAssertGreaterThanOrEqual(host.bounds.maxY - rect.maxY, 30)
    }
}
