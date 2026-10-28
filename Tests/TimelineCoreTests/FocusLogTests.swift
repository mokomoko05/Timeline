import XCTest
@testable import TimelineCore

final class FocusLogTests: XCTestCase {
    @MainActor
    func testUnlinkAndRelinkFocusNotesUpdateMarkersAndSupportUndoAndReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = Date()
        let task = try XCTUnwrap(store.addParsedTodo("Focus", on: date))
        let other = try XCTUnwrap(store.addParsedTodo("Other", on: date))
        store.setFocusTask(task.id)
        let first = try XCTUnwrap(store.quickLogEntry("First", on: date).entry)
        let second = try XCTUnwrap(store.quickLogEntry("Second", on: date).entry)
        let start = try XCTUnwrap(store.addFocusLog("▶ 开始专注", taskID: task.id, now: date, event: .start))
        XCTAssertEqual(store.setLogTask(nil, forLogs: [first.id, second.id]), 2)
        for note in store.entry(for: date).logs where [first.id, second.id].contains(note.id) {
            XCTAssertEqual(note.focusMarker, "INFO")
            XCTAssertNil(note.focusEvent)
        }
        store.undo()
        XCTAssertEqual(store.entry(for: date).logs.first?.focusMarker, "NOTE")
        store.redo()
        XCTAssertEqual(store.entry(for: date).logs.first?.focusMarker, "INFO")
        store.setLogTask(task.id, forLog: first.id, on: date)
        XCTAssertEqual(store.entry(for: date).logs.first?.focusMarker, "NOTE")
        store.setLogTask(other.id, forLog: first.id, on: date)
        XCTAssertEqual(store.entry(for: date).logs.first?.focusMarker, "INFO")
        store.setFocusTask(nil)
        store.setLogTask(task.id, forLog: second.id, on: date)
        XCTAssertEqual(store.entry(for: date).logs[1].focusMarker, "INFO")
        XCTAssertEqual(store.entry(for: date).logs.first { $0.id == start }?.focusEvent, .start)
        store.save()
        let reloaded = JournalStore(directory: directory)
        XCTAssertEqual(reloaded.entry(for: date).logs[1].focusMarker, "INFO")
        XCTAssertEqual(reloaded.entry(for: date).logs.first?.taskID, other.id)
    }

    func testMinimumStatusRoundTripsAndExistingStructuredEndsUseFiveMinuteDefault() throws {
        for seconds in [0.0, 299, 300, 301] {
            let record = DailyLogEntry(createdAt: Date(), kind: .note, text: "End", focus: true,
                                       focusEvent: .end, focusElapsedSeconds: seconds, focusMinimumSeconds: 300)
            let decoded = try JSONDecoder().decode(DailyLogEntry.self, from: JSONEncoder().encode(record))
            XCTAssertEqual(decoded, record)
            XCTAssertEqual(decoded.focusMetMinimum, seconds >= 300)
        }
        let existing = DailyLogEntry(createdAt: Date(), kind: .note, text: "■ 结束专注", focus: true,
                                     focusEvent: .end, focusElapsedSeconds: 30)
        XCTAssertEqual(existing.focusMetMinimum, false)
        let unstructured = DailyLogEntry(createdAt: Date(), kind: .note, text: "■ 结束专注", focus: true)
        XCTAssertNil(unstructured.focusMetMinimum, "旧记录缺少时长时不猜测是否达标")
        let start = DailyLogEntry(createdAt: Date(), kind: .note, text: "Start", focusEvent: .start)
        XCTAssertNil(start.focusMetMinimum)
    }

    func testMetadataRoundTripsAndOldEntriesKeepTheirTextAndTimestamp() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_027)
        let record = DailyLogEntry(createdAt: now, kind: .note, text: "▶ 开始专注", focus: true,
                                   focusEvent: .start, focusGoal: "Understand **methods**\nCompare assumptions", focusPlannedSeconds: 1500)
        let encoded = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(DailyLogEntry.self, from: encoded), record)
        XCTAssertEqual(record.focusMarker, "FOCUS")
        XCTAssertTrue(record.copyText?.contains("Compare assumptions") == true)
        XCTAssertTrue(record.searchableText.contains("methods"))
        let legacy = DailyLogEntry(createdAt: now, kind: .note, text: "■ 结束专注", focus: true)
        let reloaded = try JSONDecoder().decode(DailyLogEntry.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(reloaded.focusEvent)
        XCTAssertEqual(reloaded.focusMarker, "END")
        XCTAssertEqual(reloaded.createdAt, now)
        XCTAssertEqual(reloaded.text, legacy.text)
        XCTAssertFalse(reloaded.isNotebookEntry)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["focusEvent"] = "future-event"
        let forward = try JSONDecoder().decode(DailyLogEntry.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(forward.focusGoal, record.focusGoal)
        XCTAssertEqual(forward.focusMarker, "FOCUS")
    }

    func testMarkersDoNotMisclassifyOrdinaryNotesMentioningReflection() {
        for text in ["如何设计阶段反馈？", "今天读到 Session reflection 这个概念", "▶ just a symbol"] {
            XCTAssertEqual(DailyLogEntry(createdAt: Date(), kind: .note, text: text).focusMarker, "INFO")
        }
        for prefix in ["阶段反馈 · ", "Session reflection · "] {
            XCTAssertEqual(DailyLogEntry(createdAt: Date(), kind: .note, text: prefix + "finished").focusMarker, "REVIEW")
        }
    }

    @MainActor
    func testFocusNotesAndEventsPersistAcrossNotebookTagExportAndUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let now = Date()
        let task = try XCTUnwrap(store.addParsedTodo("Read #reading", on: now))
        let start = try XCTUnwrap(store.addFocusLog("▶ 开始专注", taskID: task.id, now: now,
                                                  event: .start, goal: "Read methods", plannedSeconds: 1500))
        store.setFocusTask(task.id)
        let note = try XCTUnwrap(store.quickLogEntry("A **finding**", on: now, now: now.addingTimeInterval(1)).entry)
        XCTAssertEqual(note.focusMarker, "NOTE")
        store.setLogDraft("/block Missing data", on: now)
        try store.commitLog(on: now, now: now.addingTimeInterval(2))
        XCTAssertEqual(store.entry(for: now).logs.last?.focusMarker, "BLOCK")
        store.setFocusPaused(true)
        let paused = try XCTUnwrap(store.quickLogEntry("Unrelated", on: now, now: now.addingTimeInterval(3)).entry)
        XCTAssertEqual(paused.focusMarker, "INFO")
        XCTAssertNil(paused.taskID)
        let review = try XCTUnwrap(store.quickLogEntry("/note /done remains text", taskID: task.id, linkDefault: false,
                                                      on: now, now: now.addingTimeInterval(4), focusEvent: .review).entry)
        XCTAssertEqual(review.focusMarker, "REVIEW")
        XCTAssertEqual(review.text, "/done remains text")
        let end = try XCTUnwrap(store.addFocusLog("■ 结束专注", taskID: task.id, now: now.addingTimeInterval(5), seconds: 1500,
                                                event: .end, endReason: "计时结束"))
        XCTAssertEqual(store.notes(for: task.id).map(\.id), [note.id, store.entry(for: now).logs[2].id])
        XCTAssertEqual(store.notes(forTag: "reading").count, 2)
        XCTAssertEqual(store.noteTopic(for: task.id)?.count, 2)
        XCTAssertEqual(store.logs(forTag: "reading").count, 5)
        XCTAssertEqual(store.allLogs(includeFocus: true).map(\.id), [start, note.id, store.entry(for: now).logs[2].id, paused.id, review.id, end])
        store.undo()
        XCTAssertEqual(store.locate(task.id)?.task.focusSeconds, 0)
        store.redo()
        store.save()
        let reloaded = JournalStore(directory: directory)
        XCTAssertEqual(reloaded.allLogs(includeFocus: true).last?.log.focusElapsedSeconds, 1500)
        XCTAssertEqual(reloaded.allLogs(includeFocus: true).first?.log.focusGoal, "Read methods")
        let exported = directory.appendingPathComponent("export.json")
        try store.export(to: exported)
        try store.restore(from: exported)
        XCTAssertEqual(store.allLogs(includeFocus: true).last?.log.focusEndReason, "计时结束")
    }

    func testOnlyFocusNotesAppearInNotebooksAndRepeatedContextIsHidden() {
        let now = Date()
        for event in [FocusLogEvent.start, .review, .end] {
            let entry = DailyLogEntry(createdAt: now, kind: .note, text: "Event", focusEvent: event)
            XCTAssertFalse(entry.isNotebookEntry)
            XCTAssertFalse(entry.showsTimelineTags)
            XCTAssertEqual(entry.showsTimelineContext, event == .start)
        }
        let note = DailyLogEntry(createdAt: now, kind: .note, text: "A finding", taskID: UUID(), focusEvent: .note)
        XCTAssertTrue(note.isNotebookEntry)
        XCTAssertFalse(note.showsTimelineContext)
        XCTAssertFalse(note.showsTimelineTags)
        var orphaned = note
        orphaned.taskID = nil
        XCTAssertEqual(orphaned.focusMarker, "INFO")
        XCTAssertFalse(orphaned.isFocusMarker)
        XCTAssertTrue(orphaned.showsTimelineContext)
        XCTAssertTrue(orphaned.showsTimelineTags)
        let reloaded = try? JSONDecoder().decode(DailyLogEntry.self, from: JSONEncoder().encode(orphaned))
        XCTAssertEqual(reloaded?.focusMarker, "INFO")
        let legacyReview = DailyLogEntry(createdAt: now, kind: .note, text: "阶段反馈 · Finished")
        XCTAssertFalse(legacyReview.isNotebookEntry)
        let ordinary = DailyLogEntry(createdAt: now, kind: .note, text: "Ordinary")
        XCTAssertTrue(ordinary.isNotebookEntry)
        XCTAssertTrue(ordinary.showsTimelineContext)
        XCTAssertTrue(ordinary.showsTimelineTags)
    }

    @MainActor
    func testHiddenReviewImagesRemainAvailableFromJournal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let now = Date()
        let task = try XCTUnwrap(store.addParsedTodo("Read #reading", on: now))
        let review = try XCTUnwrap(store.quickLogEntry("Feedback", images: ["review.png"], taskID: task.id,
                                                     on: now, focusEvent: .review).entry)
        XCTAssertTrue(store.notes(for: task.id).isEmpty)
        XCTAssertEqual(store.galleryImages(around: review).map(\.name), ["review.png"])
        XCTAssertEqual(store.noteTopic(for: task.id)?.count, 0)
    }

    func testFocusNotesAndReflectionsAreEditableButMarkersAreNot() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(DailyLogEntry(createdAt: at, kind: .note, text: "普通笔记").hasEditableText)
        XCTAssertTrue(DailyLogEntry(createdAt: at, kind: .note, text: "专注时记的", focus: true, focusEvent: .note).hasEditableText)
        XCTAssertTrue(DailyLogEntry(createdAt: at, kind: .note, text: "这一段的反馈", focus: true, focusEvent: .review).hasEditableText)
        XCTAssertFalse(DailyLogEntry(createdAt: at, kind: .note, text: "▶ 开始专注", focus: true, focusEvent: .start).hasEditableText)
        XCTAssertFalse(DailyLogEntry(createdAt: at, kind: .note, text: "■ 结束专注", focus: true, focusEvent: .end).hasEditableText)
        // 旧格式的反馈正文带着前缀，编辑会把前缀露出来：不就地编辑。
        XCTAssertFalse(DailyLogEntry(createdAt: at, kind: .note, text: "阶段反馈 · 旧的").hasEditableText)
    }
}
