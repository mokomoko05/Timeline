import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class QuickCaptureAssociationTests: XCTestCase {
    func testQuickLogDoesNotInheritFocusOrPinnedTaskButKeepsExplicitChoices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = Date()
        let focused = try XCTUnwrap(store.addParsedTodo("Focus #reading", on: date))
        let pinned = try XCTUnwrap(store.addParsedTodo("Pinned", on: date))
        store.setFocusTask(focused.id)
        store.pinTask(pinned.id)
        let model = QuickCaptureModel()
        model.text = "Unrelated thought"
        model.tags = ["idea"]
        let unrelated = try XCTUnwrap(model.recordLog(in: store).entry)
        XCTAssertNil(unrelated.taskID)
        XCTAssertEqual(unrelated.focusMarker, "INFO")
        XCTAssertEqual(unrelated.tags, ["idea"])
        model.link = focused.id
        let explicit = try XCTUnwrap(model.recordLog(in: store).entry)
        XCTAssertEqual(explicit.taskID, focused.id)
        XCTAssertEqual(explicit.focusMarker, "NOTE")
        model.link = nil
        model.text = "#\(pinned.task.number!) Explicit reference"
        let referenced = try XCTUnwrap(model.recordLog(in: store).entry)
        XCTAssertEqual(referenced.taskID, pinned.id)
        XCTAssertEqual(referenced.text, "Explicit reference")
        store.setFocusTask(nil)
        model.text = "Still unrelated"
        XCTAssertNil(try model.recordLog(in: store).entry?.taskID)
    }

    func testFocusPanelNoteUsesCurrentTaskAndUnlinkChangesTimelineColor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let task = try XCTUnwrap(store.addParsedTodo("Focus", on: Date()))
        let session = FocusSession()
        session.store = store
        session.start(task: task, url: nil)
        defer { session.stop(reason: "test") }
        let draft = FocusNoteDraft()
        draft.text = "Finding"
        XCTAssertTrue(draft.save(session: session))
        let note = try XCTUnwrap(store.allLogs().first?.log)
        XCTAssertEqual(note.taskID, task.id)
        XCTAssertEqual(note.focusEvent, .note)
        XCTAssertEqual(LogEventStyle.color(note), Palette.note)
        store.setLogTask(nil, forLog: note.id, on: note.createdAt)
        let unlinked = try XCTUnwrap(store.allLogs().first?.log)
        XCTAssertNil(unlinked.focusEvent)
        XCTAssertEqual(unlinked.focusMarker, "INFO")
        XCTAssertEqual(LogEventStyle.color(unlinked), Palette.muted)
        XCTAssertFalse(unlinked.isFocusMarker)
        store.setLogTask(task.id, forLog: note.id, on: note.createdAt)
        XCTAssertEqual(store.allLogs().first?.log.focusMarker, "NOTE")
    }
}
