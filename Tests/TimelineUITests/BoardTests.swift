import AppKit
import SwiftUI
import WebKit
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class BoardWindowTests: XCTestCase {
    func testNativeRepeatedEscapeDoesNotHideBoard() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "timeline-board-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = JournalStore(directory: directory)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Keyboard")))
        store.setBoardMarkdown("Keyboard input", for: board.id)
        let controller = BoardWindowController(defaults: defaults)
        controller.show(store: store, owner: board.owner)
        defer { controller.hide() }
        let panel = try XCTUnwrap(controller.panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        let editor = try boardWebView(in: XCTUnwrap(panel.contentView))
        try await waitForBoardEditor(editor)
        let session = controller.navigation.editorSession(for: try XCTUnwrap(store.board(for: board.owner)), store: store)
        session.configure(fontSize: 13, dark: true)
        panel.makeKey()
        panel.makeFirstResponder(editor)
        _ = try await editor.evaluateJavaScript("window.boardEditor.focus()")
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        panel.sendEvent(escape)
        panel.sendEvent(escape)
        panel.cancelOperation(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.firstResponder === editor || (panel.firstResponder as? NSView)?.isDescendant(of: editor) == true)
        let snapshot = try await editor.evaluateJavaScript("window.boardEditor.snapshot()") as? [String: Any]
        XCTAssertEqual(snapshot?["source"] as? String, "Keyboard input")
    }

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

    func testBoardContentFitsCompactPanelAndRendersMarkdownLinks() async throws {
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
        let editor = try boardWebView(in: XCTUnwrap(panel.contentView))
        try await waitForBoardEditor(editor)
        let links = try await editor.evaluateJavaScript("[...document.querySelectorAll('[data-url]')].map(e=>e.dataset.url)") as? [String]
        XCTAssertEqual(links, ["https://example.com"])
        let rendered = try await editor.evaluateJavaScript("document.querySelector('.cm-content').textContent") as? String ?? ""
        XCTAssertFalse(rendered.contains("# Background"))
        XCTAssertTrue(rendered.contains("Background"))
        if let destination = ProcessInfo.processInfo.environment["TIMELINE_BOARD_SNAPSHOT"],
           let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination))
        }
        _ = try await editor.evaluateJavaScript("document.querySelectorAll('.board-check')[1].click()")
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(store.boards.first { $0.id == board.id }?.markdown.contains("- [x] Design") == true)
        _ = try await editor.evaluateJavaScript("document.querySelectorAll('.board-check')[0].click()")
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(store.boards.first { $0.id == board.id }?.markdown.contains("- [ ] Intro & Abstract") == true)
        store.save()
        XCTAssertEqual(JournalStore(directory: directory).boards.first { $0.id == board.id }?.markdown,
                       store.boards.first { $0.id == board.id }?.markdown)
    }

    func testLiveEditorSavesTextDeletionAndPersistsOnHide() async throws {
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
        let editor = try boardWebView(in: XCTUnwrap(panel.contentView))
        try await waitForBoardEditor(editor)
        let source = "# Meeting\n\nTalking points\n\n[Reference](https://example.com)"
        let encoded = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        _ = try await editor.evaluateJavaScript("window.boardEditor.replaceSelection(\(encoded))")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.boards.first?.markdown, source)
        _ = try await editor.evaluateJavaScript("window.boardEditor.select(0,window.boardEditor.snapshot().source.length);window.boardEditor.replaceSelection('')")
        controller.hide()
        try await Task.sleep(for: .milliseconds(100))
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
        let editor = try boardWebView(in: XCTUnwrap(panel.contentView))
        try await waitForBoardEditor(editor)
        _ = try await editor.evaluateJavaScript("window.boardEditor.select(12)")
        XCTAssertEqual(store.boards.first { $0.id == board.id }?.markdown, source)
        controller.navigation.select(other.id)
        try await Task.sleep(for: .milliseconds(100))
        controller.navigation.select(board.id)
        try await Task.sleep(for: .milliseconds(100))
        panel.contentView?.layoutSubtreeIfNeeded()
        let reopened = try boardWebView(in: XCTUnwrap(panel.contentView))
        XCTAssertTrue(reopened === editor)
        let snapshot = try await reopened.evaluateJavaScript("window.boardEditor.snapshot()") as? [String: Any]
        XCTAssertEqual(snapshot?["source"] as? String, source)
        XCTAssertEqual(snapshot?["head"] as? Int, 12)
        controller.hide()
        try await Task.sleep(for: .milliseconds(50))
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
