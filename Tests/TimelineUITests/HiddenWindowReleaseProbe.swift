import AppKit
import SwiftUI
import WebKit
import XCTest
import TimelineCore
@testable import Timeline

/// 隐藏窗口释放界面的效果：`TIMELINE_MEMORY_PROBE=<含 journal.json 的目录>` 时才运行。
/// 和应用里一样每一步都在事件循环里跑（async），释放的对象能真正回收。打开主窗口、笔记（翻两周日记）、工作板，
/// 隐藏后等释放，测本进程和编辑器网页进程的占用；再测重新打开要多久（释放过 vs 没释放）。
@MainActor
final class HiddenWindowReleaseProbe: XCTestCase {
    private static func footprint(_ pid: pid_t) -> Double {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : 0
    }

    private var webPID: pid_t = 0

    private func report(_ label: String) async throws {
        try await Task.sleep(for: .milliseconds(800))
        let web = webPID > 0 ? Self.footprint(webPID) : 0
        print(String(format: "PROBE %-34@ app %6.1f MB  web %6.1f MB", label as NSString, Self.footprint(getpid()), web))
    }

    private func textViews(_ view: NSView?) -> Int {
        guard let view else { return 0 }
        return (view is InteractiveTaskText ? 1 : 0) + view.subviews.reduce(0) { $0 + textViews($1) }
    }

    /// 等到窗口里排出了正文（有文字视图），返回耗时。
    private func timeUntilContent(_ window: NSWindow?, _ start: CFAbsoluteTime) async throws -> String {
        for _ in 0..<500 {
            window?.contentView?.layoutSubtreeIfNeeded()
            if textViews(window?.contentView) > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        return String(format: "%.0fms", (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    func testHiddenWindowsReleaseTheirContent() async throws {
        guard let source = ProcessInfo.processInfo.environment["TIMELINE_MEMORY_PROBE"] else { throw XCTSkip("probe only") }
        defer { HiddenContentReleaser.delayOverride = nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = URL(fileURLWithPath: source)
        try FileManager.default.copyItem(at: sourceURL.appendingPathComponent("journal.json"), to: directory.appendingPathComponent("journal.json"))
        let images = sourceURL.appendingPathComponent("Images")
        if FileManager.default.fileExists(atPath: images.path) {
            try FileManager.default.copyItem(at: images, to: directory.appendingPathComponent("Images"))
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        try await report("baseline")

        // 主窗口：和应用里一样的内容和释放方式。
        let focus = FocusSession()
        focus.store = store
        let main = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1414, height: 864), styleMask: [.titled, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        func mainContent() -> NSView {
            NSHostingView(rootView: LocalizedRoot {
                ContentView(store: store, loginItem: LoginItem())
                    .environmentObject(ReminderScheduler(store: store)).environmentObject(WorkspaceInteraction())
                    .environmentObject(CommandCenter()).environmentObject(ToastCenter()).environment(\.focusSession, focus)
            })
        }
        main.contentView = mainContent()
        let mainReleaser = HiddenContentReleaser(window: main, delay: .seconds(1), release: { main.contentView = nil }, rebuild: { main.contentView = mainContent() })
        main.orderBack(nil)

        let notes = NotesWindowController(nav: NotesNavigation(defaults: InMemoryDefaults()))
        notes.showJournal(store: store, date: Date())
        for offset in 1...14 {
            notes.setDate(Calendar.current.date(byAdding: .day, value: -offset, to: Date())!)
            try await Task.sleep(for: .milliseconds(60))
        }
        notes.setDate(Date())

        let boards = BoardWindowController(defaults: InMemoryDefaults())
        let board = try XCTUnwrap(store.boards.max { $0.markdown.count < $1.markdown.count })
        boards.show(store: store, owner: board.owner)
        let session = boards.navigation.editorSession(for: board, store: store)
        for _ in 0..<300 where !session.ready { try await Task.sleep(for: .milliseconds(10)) }
        webPID = (session.webView?.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
        try await report("main + notes + board open")

        // 分开释放，看每个窗口各省多少（不等计时，逐个立即释放）。
        HiddenContentReleaser.delayOverride = .seconds(1000)
        main.orderOut(nil)
        notes.close()
        boards.hide()
        try await report("all hidden (before release)")
        mainReleaser.releaseNow()
        try await report("main released")
        boards.releaseHiddenContentNow()
        try await report("+ board released")
        HiddenContentReleaser.delayOverride = .seconds(1)
        print("PROBE   released: main \(mainReleaser.released), board editor alive \(BoardLiveEditorSession.hasSharedEditor)")

        // 重新打开：释放过的要重建。
        var start = CFAbsoluteTimeGetCurrent()
        notes.showJournal(store: store, date: Date())
        print("PROBE reopen notes (not released):", try await timeUntilContent(notes.window, start))
        start = CFAbsoluteTimeGetCurrent()
        mainReleaser.restoreIfNeeded()
        main.orderBack(nil)
        print("PROBE reopen main after release:", try await timeUntilContent(main, start))
        start = CFAbsoluteTimeGetCurrent()
        boards.show(store: store, owner: board.owner)
        let reopened = boards.navigation.editorSession(for: board, store: store)
        for _ in 0..<500 where !reopened.ready { try await Task.sleep(for: .milliseconds(2)) }
        print(String(format: "PROBE reopen board after release: editor ready %.0fms", (CFAbsoluteTimeGetCurrent() - start) * 1000))
        webPID = (reopened.webView?.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
        try await report("reopened")

        // 对照：隐藏一下马上打开（没释放）。
        notes.close()
        try await Task.sleep(for: .milliseconds(100))
        start = CFAbsoluteTimeGetCurrent()
        notes.showJournal(store: store, date: Date())
        print("PROBE reopen notes without release:", try await timeUntilContent(notes.window, start))
        start = CFAbsoluteTimeGetCurrent()
        boards.hide()
        try await Task.sleep(for: .milliseconds(100))
        start = CFAbsoluteTimeGetCurrent()
        boards.show(store: store, owner: board.owner)
        print(String(format: "PROBE reopen board without release: %.0fms (ready \(reopened.ready))", (CFAbsoluteTimeGetCurrent() - start) * 1000))

        notes.close()
        boards.hide()
        main.orderOut(nil)
        main.contentView = nil
    }
}
