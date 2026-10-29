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
        let model = QuickCaptureModel(defaults: InMemoryDefaults())
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

    func testCompletedTaskAndAnyTagsCanBePinnedAcrossSubmissionsAndRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let task = try XCTUnwrap(store.addParsedTodo("Done", on: Date()))
        store.toggleTodo(task.id, on: task.date)
        let defaults = InMemoryDefaults()
        let model = QuickCaptureModel(defaults: defaults)
        model.link = task.id
        model.tags = ["project/closed", "临时"]
        model.togglePinnedTask(task.id)
        model.togglePinnedTag("project/closed")
        model.text = "First"
        XCTAssertEqual(try model.recordLog(in: store).entry?.taskID, task.id)
        model.clearDraft()
        XCTAssertEqual(model.link, task.id)
        XCTAssertEqual(model.tags, ["project/closed"])
        XCTAssertFalse(model.hasDraft, "固定项本身不应触发草稿提示、遮住固定按钮")
        let restored = QuickCaptureModel(defaults: defaults)
        restored.text = "Second"
        let entry = try XCTUnwrap(restored.recordLog(in: store).entry)
        XCTAssertEqual(entry.taskID, task.id)
        XCTAssertEqual(entry.tags, ["project/closed"])
        restored.togglePinnedTask(task.id)
        restored.togglePinnedTag("project/closed")
        restored.clearDraft()
        XCTAssertNil(restored.link)
        XCTAssertTrue(restored.tags.isEmpty)
        XCTAssertNil(QuickCaptureModel(defaults: defaults).link)
        model.togglePinnedTask(task.id)
        model.resetLogAssociations()
        store.deleteTodo(task.id, on: task.date)
        model.validateTask(in: store)
        XCTAssertNil(model.pinnedLink)
        XCTAssertNil(model.link)
        XCTAssertNil(QuickCaptureModel(defaults: defaults).pinnedLink)
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
