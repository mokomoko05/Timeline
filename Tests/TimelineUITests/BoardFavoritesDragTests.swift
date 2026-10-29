import AppKit
import SwiftUI
import WebKit
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class BoardFavoritesDragTests: XCTestCase {
    func testLegacyFavoritesMigrateOnceAndRemoteOrderRefreshesTheMacBar() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let boards = try ["A", "B", "C"].map { try XCTUnwrap(store.ensureBoard(for: .tag($0))) }
        let defaults = InMemoryDefaults()
        defaults.set(boards.map { $0.id.uuidString }, forKey: "board.favorites")
        let navigation = BoardNavigation(defaults: defaults)
        navigation.connectFavorites(to: store)
        XCTAssertEqual(store.favoriteBoardIDs, boards.map(\.id))
        store.setBoardFavoriteOrder([boards[2].id, boards[0].id])
        await Task.yield()
        XCTAssertEqual(navigation.favoriteBoards(in: store).map(\.id), [boards[2].id, boards[0].id])
        navigation.moveFavorite(boards[0].id, to: 0)
        XCTAssertEqual(store.favoriteBoardIDs, [boards[0].id, boards[2].id])
        // 另一份旧偏好不能覆盖已同步的顺序，包括显式清空的收藏。
        store.setBoardFavoriteOrder([])
        let stale = BoardNavigation(defaults: defaults)
        stale.connectFavorites(to: store)
        XCTAssertTrue(stale.favoriteBoardIDs.isEmpty)
        XCTAssertEqual(store.boardFavoriteOrder, [])
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func center(_ button: NSView) -> NSPoint {
        button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    }

    private func window(containing view: NSView, width: CGFloat = 500) -> NSWindow {
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 46),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    func testNativeMouseDragAnimatesNeighborsAndPersistsWithoutSelecting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = InMemoryDefaults()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = JournalStore(directory: directory)
        let boards = try ["A", "A-much-longer-favorite", "论文"].map {
            try XCTUnwrap(store.ensureBoard(for: .tag($0)))
        }
        let navigation = BoardNavigation(defaults: defaults)
        for board in boards { navigation.toggleFavorite(board.id) }
        navigation.selection = boards[0].id
        let host = NSHostingView(rootView: BoardFavoritesBar(
            boards: boards.map { BoardFavorite(id: $0.id, title: store.boardTitle($0)) },
            selection: boards[0].id, select: { navigation.selection = $0 },
            move: { navigation.moveFavorite($0, to: $1) }, remove: { navigation.toggleFavorite($0) }))
        let window = window(containing: host)
        defer { window.contentView = nil; window.close() }
        func bars(_ view: NSView) -> [BoardFavoritesScrollView] {
            (view as? BoardFavoritesScrollView).map { [$0] } ?? view.subviews.flatMap(bars)
        }
        let bar = try XCTUnwrap(bars(host).first)
        let first = try XCTUnwrap(bar.buttons[boards[0].id])
        let second = try XCTUnwrap(bar.buttons[boards[1].id])
        let last = try XCTUnwrap(bar.buttons[boards[2].id])
        let start = center(first)
        let destination = center(last)
        let originalFirst = first.frame
        let originalSecond = second.frame
        XCTAssertTrue(host.hitTest(host.superview?.convert(start, from: nil) ?? start) === first)
        first.mouseDown(with: try event(.leftMouseDown, at: start, window: window))
        first.mouseDragged(with: try event(.leftMouseDragged, at: destination, window: window))
        XCTAssertEqual(bar.draggedID, boards[0].id)
        XCTAssertTrue(first.dragging)
        XCTAssertEqual(first.layer?.shadowOpacity, 0.3)
        XCTAssertGreaterThan(first.frame.minX, originalFirst.minX)
        XCTAssertEqual(bar.previewOrder, [boards[1].id, boards[2].id, boards[0].id])
        XCTAssertEqual(navigation.favoriteBoardIDs, boards.map(\.id))
        if let path = ProcessInfo.processInfo.environment["TIMELINE_BOARD_DRAG_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        first.mouseUp(with: try event(.leftMouseUp, at: destination, window: window))
        XCTAssertNil(bar.draggedID)
        XCTAssertFalse(first.dragging)
        XCTAssertEqual(navigation.selection, boards[0].id)
        XCTAssertEqual(BoardNavigation(defaults: defaults).favoriteBoardIDs, [boards[1].id, boards[2].id, boards[0].id])
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertLessThan(second.frame.minX, originalSecond.minX)
        XCTAssertGreaterThan(first.frame.minX, last.frame.minX)
    }

    func testDragBackwardsCancelAndClickUseTheRealButtons() throws {
        let boards = ["First", "A wider second board", "Last"].map { BoardFavorite(id: UUID(), title: $0) }
        let bar = BoardFavoritesScrollView()
        let window = window(containing: bar)
        defer { window.contentView = nil; window.close() }
        bar.configure(boards: boards, selection: boards[0].id, fontSize: 11)
        var moves: [(UUID, Int)] = []
        var selections: [UUID] = []
        bar.onMove = { moves.append(($0, $1)) }
        bar.onSelect = { selections.append($0) }
        let first = try XCTUnwrap(bar.buttons[boards[0].id])
        let last = try XCTUnwrap(bar.buttons[boards[2].id])
        let start = center(last)
        let destination = center(first)
        last.mouseDown(with: try event(.leftMouseDown, at: start, window: window))
        last.mouseDragged(with: try event(.leftMouseDragged, at: destination, window: window))
        XCTAssertEqual(bar.previewOrder, [boards[2].id, boards[0].id, boards[1].id])
        last.cancelOperation(nil)
        last.mouseUp(with: try event(.leftMouseUp, at: destination, window: window))
        XCTAssertNil(bar.draggedID)
        XCTAssertEqual(bar.previewOrder, boards.map(\.id))
        XCTAssertTrue(moves.isEmpty)
        XCTAssertTrue(selections.isEmpty)
        let point = center(first)
        XCTAssertEqual(first.focusRingType, .none)
        XCTAssertEqual(bar.focusRingType, .none)
        first.mouseDown(with: try event(.leftMouseDown, at: point, window: window))
        XCTAssertTrue(first.pressing)
        XCTAssertTrue(selections.isEmpty)
        first.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: point.x + 2, y: point.y), window: window))
        first.mouseUp(with: try event(.leftMouseUp, at: point, window: window))
        XCTAssertFalse(first.pressing)
        XCTAssertEqual(selections, [boards[0].id])
        first.mouseDown(with: try event(.leftMouseDown, at: point, window: window))
        first.cancelOperation(nil)
        first.mouseUp(with: try event(.leftMouseUp, at: point, window: window))
        XCTAssertFalse(first.pressing)
        XCTAssertEqual(selections, [boards[0].id])
        last.mouseDown(with: try event(.leftMouseDown, at: start, window: window))
        last.mouseDragged(with: try event(.leftMouseDragged, at: destination, window: window))
        last.mouseUp(with: try event(.leftMouseUp, at: destination, window: window))
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.first?.0, boards[2].id)
        XCTAssertEqual(moves.first?.1, 0)
    }

    func testDraggingAfterHorizontalScrollUsesDocumentCoordinatesAndRemovalCancels() throws {
        let boards = (0..<8).map { BoardFavorite(id: UUID(), title: "Favorite \($0)") }
        let bar = BoardFavoritesScrollView()
        let window = window(containing: bar, width: 220)
        defer { window.contentView = nil; window.close() }
        bar.configure(boards: boards, selection: nil, fontSize: 11)
        bar.contentView.scroll(to: NSPoint(x: 180, y: 0))
        let button = try XCTUnwrap(bar.buttons[boards[3].id])
        let start = center(button)
        button.mouseDown(with: try event(.leftMouseDown, at: start, window: window))
        let destination = NSPoint(x: start.x + 140, y: start.y)
        button.mouseDragged(with: try event(.leftMouseDragged, at: destination, window: window))
        XCTAssertEqual(bar.draggedID, boards[3].id)
        bar.setFrameSize(bar.frame.size)
        XCTAssertEqual(bar.draggedID, boards[3].id)
        XCTAssertGreaterThan(try XCTUnwrap(bar.previewOrder.firstIndex(of: boards[3].id)), 3)
        var moved = false
        bar.onMove = { _, _ in moved = true }
        bar.configure(boards: Array(boards.dropFirst(4)), selection: nil, fontSize: 11)
        button.mouseUp(with: try event(.leftMouseUp, at: destination, window: window))
        XCTAssertNil(bar.draggedID)
        XCTAssertFalse(moved)
        XCTAssertNil(bar.buttons[boards[3].id])
    }

    func testSwitchingFavoritesKeepsDraftsAndDoesNotFlushTheJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = InMemoryDefaults()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = JournalStore(directory: directory)
        let first = try XCTUnwrap(store.ensureBoard(for: .tag("Draft")))
        let second = try XCTUnwrap(store.ensureBoard(for: .tag("Reading")))
        store.setBoardMarkdown("# Reading", for: second.id)
        store.save()
        let controller = BoardWindowController(defaults: defaults)
        controller.navigation.toggleFavorite(first.id)
        controller.navigation.toggleFavorite(second.id)
        controller.show(store: store, owner: first.owner)
        defer { controller.hide() }
        let panel = try XCTUnwrap(controller.panel)
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded()
        func bars(_ view: NSView) -> [BoardFavoritesScrollView] {
            (view as? BoardFavoritesScrollView).map { [$0] } ?? view.subviews.flatMap(bars)
        }
        let editor = try await waitForBoardEditor(in: content)
        _ = try await editor.evaluateJavaScript("window.boardEditor.focus();window.boardEditor.replaceSelection('Unsaved meeting notes')")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.board(for: first.owner)?.markdown, "")
        XCTAssertFalse(store.hasPendingSave)
        let saved = store.lastSaved
        let bar = try XCTUnwrap(bars(content).first)
        let button = try XCTUnwrap(bar.buttons[second.id])
        let frame = button.frame
        let point = center(button)
        button.mouseDown(with: try event(.leftMouseDown, at: point, window: panel))
        button.mouseUp(with: try event(.leftMouseUp, at: point, window: panel))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.navigation.selection, second.id)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(store.board(for: first.owner)?.markdown, "Unsaved meeting notes")
        XCTAssertEqual(store.lastSaved, saved)
        XCTAssertTrue(store.hasPendingSave)
        XCTAssertEqual(button.frame, frame)
        XCTAssertTrue(button.selected)
        controller.hide()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(JournalStore(directory: directory).board(for: first.owner)?.markdown, "Unsaved meeting notes")
    }

    func testFloatingBoardPanelRoutesMouseEventsAndKeepsTheNewOrderAfterReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = InMemoryDefaults()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = JournalStore(directory: directory)
        let controller = BoardWindowController(defaults: defaults)
        let boards = try ["Reading", "Meeting", "Research"].map {
            try XCTUnwrap(store.ensureBoard(for: .tag($0)))
        }
        for board in boards { controller.navigation.toggleFavorite(board.id) }
        controller.show(store: store, owner: boards[1].owner)
        defer { controller.hide() }
        let panel = try XCTUnwrap(controller.panel)
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded()
        func bars(_ view: NSView) -> [BoardFavoritesScrollView] {
            (view as? BoardFavoritesScrollView).map { [$0] } ?? view.subviews.flatMap(bars)
        }
        let bar = try XCTUnwrap(bars(content).first)
        let first = try XCTUnwrap(bar.buttons[boards[0].id])
        let last = try XCTUnwrap(bar.buttons[boards[2].id])
        let start = center(first)
        let destination = center(last)
        let hit = try XCTUnwrap(content.hitTest(content.superview?.convert(start, from: nil) ?? start) as? BoardFavoriteButton)
        XCTAssertTrue(hit === first)
        hit.mouseDown(with: try event(.leftMouseDown, at: start, window: panel))
        hit.mouseDragged(with: try event(.leftMouseDragged, at: destination, window: panel))
        XCTAssertEqual(bar.draggedID, boards[0].id)
        hit.mouseUp(with: try event(.leftMouseUp, at: destination, window: panel))
        let expected = [boards[1].id, boards[2].id, boards[0].id]
        XCTAssertEqual(controller.navigation.favoriteBoardIDs, expected)
        XCTAssertEqual(controller.navigation.selection, boards[1].id)
        try await Task.sleep(for: .milliseconds(220))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.boards.map(\.id), expected)
        XCTAssertLessThan(last.frame.minX, first.frame.minX)
        controller.hide()
        controller.show(store: store)
        XCTAssertEqual(BoardNavigation(defaults: defaults).favoriteBoardIDs, expected)
        panel.contentView?.layoutSubtreeIfNeeded()
        let reopened = try XCTUnwrap(bars(try XCTUnwrap(panel.contentView)).first)
        XCTAssertEqual(reopened.boards.map(\.id), expected)
    }
}
