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
        store.applyBoardTemplate(["Intro", "Design"], to: board.id)
        let controller = BoardWindowController(defaults: defaults)
        controller.show(store: store, owner: .tag("reading"))
        let panel = try XCTUnwrap(controller.panel)
        defer { controller.hide() }
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        panel.resignKey()
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(controller.navigation.selection, board.id)
        controller.toggle(store: store)
        XCTAssertFalse(panel.isVisible)
        controller.toggle(store: store)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(controller.panel === panel)
        XCTAssertEqual(BoardNavigation(defaults: defaults).selection, board.id)
        let item = try XCTUnwrap(store.boards[0].items.first)
        controller.navigation.toggleCollapsed(item.id)
        XCTAssertTrue(BoardNavigation(defaults: defaults).collapsed(item.id))
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
        store.addBoardItem(to: board.id, title: "Background", body: "想弄清楚的问题\n\n[论文链接](https://example.com)")
        let controller = BoardWindowController(defaults: defaults)
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
        if let destination = ProcessInfo.processInfo.environment["TIMELINE_BOARD_SNAPSHOT"],
           let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination))
        }
    }
}
