import AppKit
import SwiftUI
import XCTest
import DayleafCore
@testable import Dayleaf

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
        XCTAssertGreaterThanOrEqual(scroll.bounds.height, 30)
        XCTAssertGreaterThanOrEqual(host.bounds.maxY - rect.maxY, 30)
    }
}
