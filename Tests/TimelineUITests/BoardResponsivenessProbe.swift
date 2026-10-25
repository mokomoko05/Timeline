import AppKit
import SwiftUI
import WebKit
import XCTest
import TimelineCore
@testable import Timeline

/// 工作板各操作的耗时探测：`TIMELINE_BOARD_PROBE=<含 journal.json 的目录>` 时才运行。
/// 窗口是透明、不接收鼠标、放在最底层的 QuietWindow，不会出现在屏幕上，也不抢焦点。
@MainActor
final class BoardResponsivenessProbe: XCTestCase {
    private func ms(_ start: CFAbsoluteTime) -> String { String(format: "%.1fms", (CFAbsoluteTimeGetCurrent() - start) * 1000) }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    }

    func testMeasureBoardActions() throws {
        guard let source = ProcessInfo.processInfo.environment["TIMELINE_BOARD_PROBE"] else { throw XCTSkip("probe only") }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent("journal.json"),
                                         to: directory.appendingPathComponent("journal.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let suite = "board-probe-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = BoardNavigation(defaults: defaults)
        print("PROBE data: tasks \(store.tasks().count) boards \(store.boards.count) tags \(store.allTags().count)")

        var t = CFAbsoluteTimeGetCurrent()
        store.save()
        print("PROBE store.save(): \(ms(t))")

        // 切换弹窗第一次排版
        t = CFAbsoluteTimeGetCurrent()
        let chooser = NSHostingView(rootView: BoardSwitcher(store: store, navigation: navigation, close: {}).frame(width: 390))
        chooser.frame = NSRect(x: 0, y: 0, width: 390, height: 400)
        chooser.layoutSubtreeIfNeeded()
        print("PROBE switcher first layout: \(ms(t))")
        for round in 0..<3 {
            t = CFAbsoluteTimeGetCurrent()
            let again = NSHostingView(rootView: BoardSwitcher(store: store, navigation: navigation, close: {}).frame(width: 390))
            again.frame = NSRect(x: 0, y: 0, width: 390, height: 400)
            again.layoutSubtreeIfNeeded()
            print("PROBE switcher warm layout #\(round): \(ms(t))")
        }
        t = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 { _ = BoardSwitcherItem.items(store: store, favorites: navigation.favoriteBoardIDs, query: "a") }
        print("PROBE switcher items x20: \(ms(t))")

        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: BoardWorkspaceView(store: store, navigation: navigation))
        window.contentView = host
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }

        let spareMode = ProcessInfo.processInfo.environment["TIMELINE_BOARD_SPARE"] != nil
        let owners: [BoardOwner] = store.boards.prefix(6).map(\.owner)
            + store.tasks().filter { store.board(for: .task($0.id)) == nil }.prefix(2).map { .task($0.id) }
        for (round, owner) in (owners + owners.prefix(3)).enumerated() {
            if spareMode {
                BoardLiveEditorSession.prepareSpare(after: .zero)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            }
            t = CFAbsoluteTimeGetCurrent()
            store.save()
            let saved = ms(t)
            guard let board = store.ensureBoard(for: owner) else { continue }
            navigation.select(board.id)
            host.layoutSubtreeIfNeeded()
            let layout = ms(t)
            let session = navigation.editorSession(for: board, store: store)
            spin(until: { session.ready })
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            print("PROBE switch #\(round) \(store.boardTitle(board).prefix(16)): save \(saved), swiftui \(layout), editor ready \(ms(t)) (ready=\(session.ready))")
        }
        // 两个已缓存的工作板之间来回切换
        let pair = Array(store.boards.prefix(2))
        for round in 0..<6 {
            let board = pair[round % 2]
            t = CFAbsoluteTimeGetCurrent()
            navigation.select(board.id)
            let selected = ms(t)
            let t2 = CFAbsoluteTimeGetCurrent()
            host.layoutSubtreeIfNeeded()
            let layout = ms(t2)
            let t3 = CFAbsoluteTimeGetCurrent()
            host.display()
            let draw = ms(t3)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            print("PROBE cached switch #\(round): select \(selected), layout \(layout), display \(draw)")
        }
        for round in 0..<4 {
            t = CFAbsoluteTimeGetCurrent()
            navigation.toggleFavorite(pair[0].id)
            host.layoutSubtreeIfNeeded()
            print("PROBE favorite toggle #\(round): \(ms(t))")
        }
        let session = navigation.editorSession(for: pair[0], store: store)
        for round in 0..<4 {
            t = CFAbsoluteTimeGetCurrent()
            var done = false
            session.setSourceMode(round % 2 == 0)
            session.webView?.evaluateJavaScript("1") { _, _ in done = true }
            spin(until: { done })
            print("PROBE source toggle round trip #\(round): \(ms(t))")
        }
        t = CFAbsoluteTimeGetCurrent()
        let bare = WKWebView(frame: .zero)
        print("PROBE bare WKWebView init: \(ms(t)) \(bare.hash % 2)")
        t = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 { _ = store.sortedTasks().filter { !$0.task.completed }.map { String(TaskText.rendered($0.task.title).characters) } }
        print("PROBE chooser data x20: \(ms(t))")
        t = CFAbsoluteTimeGetCurrent()
        let preview = NSHostingView(rootView: BoardMarkdownPreview(store: store, board: store.boards[0]).frame(width: 400))
        preview.layoutSubtreeIfNeeded()
        print("PROBE native preview layout: \(ms(t))")
    }
}
