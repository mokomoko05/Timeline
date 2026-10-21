import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class BoardWindowTests: XCTestCase {
    func testPanelStaysVisibleAcrossFocusLossAndRemembersSelectionWhenHidden() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "timeline-board-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Reading")))
        store.setBoardMarkdown("# Intro\n\n- [ ] Design", for: board.id)
        defaults.set(false, forKey: "board.floating")
        let controller = BoardWindowController(defaults: defaults)
        controller.show(store: store, owner: .tag("reading"))
        let panel = try XCTUnwrap(controller.panel)
        defer { controller.hide() }
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        panel.resignKey()
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(controller.navigation.selection, board.id)
        controller.toggle(store: store)
        XCTAssertFalse(panel.isVisible)
        controller.toggle(store: store)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(controller.panel === panel)
        XCTAssertEqual(BoardNavigation(defaults: defaults).selection, board.id)
        controller.navigation.toggleFavorite(board.id)
        XCTAssertTrue(BoardNavigation(defaults: defaults).isFavorite(board.id))
    }

    func testBoardContentFitsCompactPanelAndRendersMarkdownLinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "timeline-board-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Reading")))
        store.setBoardMarkdown("# Background\n\n想弄清楚的问题\n\n- [x] Intro & Abstract\n- [ ] Design\n\n[论文链接](https://example.com)", for: board.id)
        let other = try XCTUnwrap(store.ensureBoard(for: .tag("Meeting")))
        let controller = BoardWindowController(defaults: defaults)
        controller.navigation.toggleFavorite(board.id)
        controller.navigation.toggleFavorite(other.id)
        controller.show(store: store, owner: .tag("Reading"))
        defer { controller.hide() }
        let panel = try XCTUnwrap(controller.panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(panel.frame.width, 340)
        XCTAssertLessThan(panel.frame.width, 600)
        func texts(_ view: NSView) -> [InteractiveTaskText] {
            (view as? InteractiveTaskText).map { [$0] } ?? view.subviews.flatMap(texts)
        }
        let link = try XCTUnwrap(texts(try XCTUnwrap(panel.contentView)).first)
        let storage = try XCTUnwrap(link.textStorage)
        var links: [URL] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertEqual(links, [URL(string: "https://example.com")!])
        XCTAssertFalse(storage.string.contains("# Background"))
        XCTAssertTrue(storage.string.contains("Background"))
        if let destination = ProcessInfo.processInfo.environment["TIMELINE_BOARD_SNAPSHOT"],
           let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination))
        }
        let circles = link.taskRegions()
        XCTAssertEqual(circles.map(\.line), [5, 6])
        let pending = try XCTUnwrap(circles.last)
        link.activate(at: NSPoint(x: pending.rect.midX, y: pending.rect.midY))
        XCTAssertTrue(store.boards.first { $0.id == board.id }?.markdown.contains("- [x] Design") == true)
        let completed = try XCTUnwrap(circles.first)
        link.activate(at: NSPoint(x: completed.rect.midX, y: completed.rect.midY))
        XCTAssertTrue(store.boards.first { $0.id == board.id }?.markdown.contains("- [ ] Intro & Abstract") == true)
        store.save()
        XCTAssertEqual(JournalStore(directory: directory).boards.first { $0.id == board.id }?.markdown,
                       store.boards.first { $0.id == board.id }?.markdown)
    }

    func testNativeEditorSavesTextDeletionAndPersistsOnHide() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "timeline-board-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = JournalStore(directory: directory)
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let controller = BoardWindowController(defaults: defaults)
        controller.show(store: store, owner: .tag("Draft"))
        defer { controller.hide() }
        let panel = try XCTUnwrap(controller.panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        func editors(_ view: NSView) -> [NSTextView] {
            if let text = view as? NSTextView, text.isEditable { return [text] }
            return view.subviews.flatMap(editors)
        }
        let editor = try XCTUnwrap(editors(try XCTUnwrap(panel.contentView)).first)
        XCTAssertTrue(editor.allowsUndo)
        let source = "# Meeting\n\nTalking points\n\n[Reference](https://example.com)"
        editor.string = source
        editor.didChangeText()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.boards.first?.markdown, source)
        editor.string = ""
        editor.didChangeText()
        try await Task.sleep(for: .milliseconds(350))
        controller.hide()
        XCTAssertEqual(JournalStore(directory: directory).boards.first?.markdown, "")
    }

    func testFavoritesPersistInOrderAndSurviveOwnerRenameAndArchive() throws {
        let suite = "timeline-board-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = JournalStore(directory: directory)
        let first = try XCTUnwrap(store.ensureBoard(for: .tag("Reading")))
        let second = try XCTUnwrap(store.ensureBoard(for: .tag("Meeting")))
        defaults.set([second.id.uuidString, first.id.uuidString, second.id.uuidString, "bad", UUID().uuidString],
                     forKey: "board.favorites")
        let navigation = BoardNavigation(defaults: defaults)
        XCTAssertEqual(navigation.favoriteBoards(in: store).map(\.id), [second.id, first.id])
        XCTAssertEqual(store.renameTag("Reading", to: "Papers"), "Papers")
        store.deleteTag("Meeting")
        XCTAssertEqual(navigation.favoriteBoards(in: store).map(\.id), [second.id, first.id])
        XCTAssertTrue(store.isBoardArchived(navigation.favoriteBoards(in: store)[0]))
        XCTAssertEqual(store.boardTitle(navigation.favoriteBoards(in: store)[1]), "#Papers")
        navigation.toggleFavorite(second.id)
        navigation.toggleFavorite(second.id)
        XCTAssertEqual(BoardNavigation(defaults: defaults).favoriteBoards(in: store).map(\.id), [first.id, second.id])
        navigation.moveFavorite(second.id, to: 0)
        XCTAssertEqual(BoardNavigation(defaults: defaults).favoriteBoards(in: store).map(\.id), [second.id, first.id])
        navigation.moveFavorite(second.id, to: 500)
        XCTAssertEqual(BoardNavigation(defaults: defaults).favoriteBoards(in: store).map(\.id), [first.id, second.id])
        navigation.moveFavorite(first.id, to: -1)
        navigation.moveFavorite(UUID(), to: 0)
        XCTAssertEqual(BoardNavigation(defaults: defaults).favoriteBoards(in: store).map(\.id), [first.id, second.id])
    }

    func testOpeningEditorAndSwitchingBoardsPreservesExistingMarkdown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "timeline-board-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Paper")))
        let source = "# Reading\n\n- [x] Intro\n\n中文笔记与[链接](https://example.com)"
        store.setBoardMarkdown(source, for: board.id)
        let other = try XCTUnwrap(store.ensureBoard(for: .tag("Meeting")))
        let controller = BoardWindowController(defaults: defaults)
        controller.show(store: store, owner: board.owner)
        defer { controller.hide() }
        let panel = try XCTUnwrap(controller.panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        func textViews(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        let preview = try XCTUnwrap(textViews(try XCTUnwrap(panel.contentView)).compactMap { $0 as? InteractiveTaskText }.first)
        preview.onEdit?()
        try await Task.sleep(for: .milliseconds(100))
        panel.contentView?.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(textViews(try XCTUnwrap(panel.contentView)).first { $0.isEditable })
        XCTAssertEqual(editor.string, source)
        XCTAssertEqual(store.boards.first { $0.id == board.id }?.markdown, source)
        controller.navigation.selection = other.id
        try await Task.sleep(for: .milliseconds(100))
        controller.navigation.selection = board.id
        try await Task.sleep(for: .milliseconds(100))
        controller.hide()
        XCTAssertEqual(JournalStore(directory: directory).boards.first { $0.id == board.id }?.markdown, source)
    }

    func testNotesShowTheSameBoardsForTaskTagAndTagChaptersAndHideEmptyContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day = JournalDates.date(for: "2026-10-21")!
        let task = try XCTUnwrap(store.addParsedTodo("Paper #Reading", on: day))
        _ = try store.quickLog("A note", taskID: task.id, on: day)
        let taskBoard = try XCTUnwrap(store.ensureBoard(for: .task(task.id)))
        let tagBoard = try XCTUnwrap(store.ensureBoard(for: .tag("Reading")))
        let taskSource = "# Task board\n\n- [ ] Read intro"
        let tagSource = "# Tag board\n\nShared reading goals"
        store.setBoardMarkdown(taskSource, for: taskBoard.id)
        store.setBoardMarkdown(tagSource, for: tagBoard.id)
        func texts(_ view: NSView) -> [InteractiveTaskText] {
            (view as? InteractiveTaskText).map { [$0] } ?? view.subviews.flatMap(texts)
        }
        let navigation = NotesNavigation(defaults: nil)
        let host = NSHostingView(rootView: NotesView(store: store, initialSelection: task.id, nav: navigation,
                                                   reveal: { _ in }, openDay: { _ in }).frame(width: 1000, height: 800))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(texts(host).filter { $0.source == taskSource }.count, 1)
        XCTAssertFalse(texts(host).contains { $0.source == tagSource })
        navigation.open(tag: "Reading")
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(texts(host).filter { $0.source == taskSource }.count, 1)
        XCTAssertEqual(texts(host).filter { $0.source == tagSource }.count, 1)
        if let destination = ProcessInfo.processInfo.environment["TIMELINE_BOARD_NOTES_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination))
        }
        let preview = try XCTUnwrap(texts(host).first { $0.source == taskSource })
        let circle = try XCTUnwrap(preview.taskRegions().first)
        preview.activate(at: NSPoint(x: circle.rect.midX, y: circle.rect.midY))
        XCTAssertTrue(store.board(for: .task(task.id))?.markdown.contains("- [x] Read intro") == true)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(texts(host).contains { $0.source?.contains("- [x] Read intro") == true })
        store.setBoardMarkdown(" \n\t", for: taskBoard.id)
        store.setBoardMarkdown("", for: tagBoard.id)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let visible = texts(host).filter { !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }
        XCTAssertFalse(visible.contains { $0.source == tagSource || $0.source?.contains("Read intro") == true },
                       "\(visible.map { ($0.source ?? "", $0.frame) })")
    }
}
