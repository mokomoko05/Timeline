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

    /// 编辑器里显示的正好是这个工作板的正文（不只是网页就绪）。
    private func shows(_ board: Board, in store: JournalStore, session: BoardLiveEditorSession) -> Bool {
        guard session.ready, let webView = session.webView else { return false }
        let expected = store.boards.first { $0.id == board.id }?.markdown ?? board.markdown
        var matched: Bool?
        webView.evaluateJavaScript("window.boardEditor.snapshot().source") { result, _ in matched = (result as? String) == expected }
        spin(until: { matched != nil }, timeout: 1)
        return matched == true
    }

    private static func footprint(_ pid: pid_t) -> Double {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : 0
    }

    /// 本进程和所有编辑器网页内容进程的物理占用。
    private func memory(_ label: String, _ views: [WKWebView]) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let pids = Set(views.compactMap { ($0.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value }.filter { $0 > 0 })
        let web = pids.reduce(0) { $0 + Self.footprint($1) }
        print(String(format: "PROBE memory %@: app %.1f MB, web %.1f MB in %d process(es)", label, Self.footprint(getpid()), web, pids.count))
    }

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
        let defaults = InMemoryDefaults()
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
        var seenViews: [WKWebView] = []
        for (round, owner) in (owners + owners.prefix(3)).enumerated() {
            if spareMode {
                BoardLiveEditorSession.preloadEditor(after: .zero)
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
            let readyTime = ms(t)
            spin(until: { shows(board, in: store, session: session) })
            print("PROBE switch #\(round) \(store.boardTitle(board).prefix(16)): save \(saved), swiftui \(layout), editor ready \(readyTime), content shown \(ms(t))")
            if let view = session.webView, !seenViews.contains(where: { $0 === view }) { seenViews.append(view) }
        }
        memory("after switching \(owners.count) boards", seenViews)
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
            let session = navigation.editorSession(for: board, store: store)
            spin(until: { shows(board, in: store, session: session) })
            print("PROBE cached switch #\(round): select \(selected), layout \(layout), display \(draw), content shown \(ms(t))")
        }
        for round in 0..<4 {
            t = CFAbsoluteTimeGetCurrent()
            navigation.toggleFavorite(pair[0].id)
            host.layoutSubtreeIfNeeded()
            print("PROBE favorite toggle #\(round): \(ms(t))")
        }
        navigation.select(pair[0].id)
        host.layoutSubtreeIfNeeded()
        let session = navigation.editorSession(for: pair[0], store: store)
        spin(until: { shows(pair[0], in: store, session: session) })
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
