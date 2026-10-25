import AppKit
import Darwin
import SwiftUI
import WebKit
import XCTest
import TimelineCore
@testable import Timeline

/// 各窗口内容占用的内存：`TIMELINE_MEMORY_PROBE=<含 journal.json 的目录>` 时才运行。
/// 用 QuietWindow 离屏渲染（不可见、不抢焦点），每一步打印进程的物理占用（phys_footprint）和带内容的图层估算。
/// 笔记页打开笔记最多的任务；`TIMELINE_NOTES_TASK=least` 改为没有笔记的任务。
@MainActor
final class MemoryFootprintProbe: XCTestCase {
    private var last = 0.0

    private func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private func report(_ label: String) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let now = footprint()
        print(String(format: "PROBE %-28@ %7.1f MB  (%+.1f)", label as NSString, now, now - last))
        last = now
    }

    /// 有内容（backing store）的图层，按图层代理的类名汇总估算字节数。
    private func layerReport(_ window: NSWindow, label: String) {
        var totals: [String: (count: Int, bytes: Double)] = [:]
        func walk(_ layer: CALayer) {
            if layer.contents != nil {
                let scale = layer.contentsScale
                let bytes = Double(layer.bounds.width * scale) * Double(layer.bounds.height * scale) * 4
                let name = String((layer.delegate.map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))).prefix(50))
                totals[name, default: (0, 0)].count += 1
                totals[name, default: (0, 0)].bytes += bytes
            }
            layer.sublayers?.forEach(walk)
        }
        if let root = window.contentView?.superview?.layer ?? window.contentView?.layer { walk(root) }
        print(String(format: "PROBE   layers[%@] %.1f MB", label, totals.values.reduce(0) { $0 + $1.bytes } / 1_048_576))
        for (name, value) in totals.sorted(by: { $0.value.bytes > $1.value.bytes }).prefix(5) {
            print(String(format: "PROBE     %4d × %-50@ %.1f MB", value.count, name as NSString, value.bytes / 1_048_576))
        }
    }

    private func host<Content: View>(_ content: Content, size: NSSize) -> QuietWindow {
        autoreleasepool {
            let window = QuietWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LocalizedRoot { content })
            window.orderBack(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return window
        }
    }

    func testMeasureWindowFootprints() throws {
        guard let source = ProcessInfo.processInfo.environment["TIMELINE_MEMORY_PROBE"] else { throw XCTSkip("probe only") }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = URL(fileURLWithPath: source)
        try FileManager.default.copyItem(at: sourceURL.appendingPathComponent("journal.json"), to: directory.appendingPathComponent("journal.json"))
        let images = sourceURL.appendingPathComponent("Images")
        if FileManager.default.fileExists(atPath: images.path) {
            try FileManager.default.copyItem(at: images, to: directory.appendingPathComponent("Images"))
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        report("baseline")
        let store = JournalStore(directory: directory)
        report("store loaded")

        let focus = FocusSession()
        focus.store = store
        let main = host(ContentView(store: store, loginItem: LoginItem())
            .environmentObject(ReminderScheduler(store: store)).environmentObject(WorkspaceInteraction())
            .environmentObject(CommandCenter()).environmentObject(ToastCenter()).environment(\.focusSession, focus),
            size: NSSize(width: 1414, height: 864))
        report("main window")
        layerReport(main, label: "main")

        let nav = NotesNavigation(defaults: InMemoryDefaults())
        let counts = Dictionary(grouping: store.allLogs().compactMap(\.log.taskID), by: { $0 })
        let pick = ProcessInfo.processInfo.environment["TIMELINE_NOTES_TASK"] == "least"
            ? store.tasks().first(where: { counts[$0.id] == nil })?.id
            : counts.max(by: { $0.value.count < $1.value.count })?.key
        if let pick { nav.open(task: pick) }
        let workspace = NotesWorkspaceNavigation()
        let notes = host(UnifiedNotesView(store: store, workspace: workspace, nav: nav, close: {}, reveal: { _ in }, openDay: { _ in }),
                         size: NSSize(width: 1409, height: 872))
        report("notes window (\(pick.flatMap { counts[$0]?.count } ?? 0) notes)")
        layerReport(notes, label: "notes")
        workspace.open(.journal, date: Date())
        notes.contentView?.layoutSubtreeIfNeeded()
        notes.displayIfNeeded()
        report("+ journal page")

        for _ in 0..<5 { _ = try store.quickLog("probe edit", on: Date()) }
        report("5 edits, both windows alive")

        // 翻看两周的日记（每天一页）。
        // 每一步包在自动释放池里，和应用里每个事件结束时清空一样（不包的话测试方法里的临时对象会一直攒到测试结束）。
        func browse(_ offset: Int) {
            autoreleasepool {
                workspace.open(.journal, date: Calendar.current.date(byAdding: .day, value: -offset, to: Date())!)
                notes.contentView?.layoutSubtreeIfNeeded()
                notes.displayIfNeeded()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        for offset in 1...14 { browse(offset) }
        report("+ 14 journal days browsed")
        if let out = ProcessInfo.processInfo.environment["TIMELINE_MEMORY_HEAP"] {
            for (tool, args) in [("/usr/bin/vmmap", ["--summary"]), ("/usr/bin/heap", ["-s"])] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = args + [String(getpid())]
                FileManager.default.createFile(atPath: out + "." + (tool as NSString).lastPathComponent, contents: nil)
                process.standardOutput = FileHandle(forWritingAtPath: out + "." + (tool as NSString).lastPathComponent)
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        }

        if ProcessInfo.processInfo.environment["TIMELINE_MEMORY_DAYS"] != nil {
            for (label, range) in [("+ next 14 days", 15...28), ("revisit days 1-14", 1...14), ("revisit days 1-14 again", 1...14)] {
                for offset in range { browse(offset) }
                report(label)
                func count(_ view: NSView?) -> Int { guard let view else { return 0 } ; return (view is InteractiveTaskText ? 1 : 0) + view.subviews.reduce(0) { $0 + count($1) } }
                print("PROBE   InteractiveTaskText in windows:", count(main.contentView) + count(notes.contentView))
            }
            if let out = ProcessInfo.processInfo.environment["TIMELINE_MEMORY_HEAP"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
                process.arguments = [String(getpid())]
                let vmmap = Process()
                vmmap.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
                vmmap.arguments = ["--summary", String(getpid())]
                FileManager.default.createFile(atPath: out + ".after.vmmap", contents: nil)
                vmmap.standardOutput = FileHandle(forWritingAtPath: out + ".after.vmmap")
                vmmap.standardError = FileHandle.nullDevice
                try? vmmap.run()
                vmmap.waitUntilExit()
                FileManager.default.createFile(atPath: out + ".after", contents: nil)
                process.standardOutput = FileHandle(forWritingAtPath: out + ".after")
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        }

        // 全局搜索：常见字，包含图片文字。
        let started = Date()
        let hits = GlobalSearch.hits(store: store, query: "的")
        report(String(format: "search \"的\" %d hits %.0fms", hits.count, Date().timeIntervalSince(started) * 1000))

        // 工作板编辑器：每个编辑器一份 WebKit 内容进程（不算在本进程里），分开统计。
        var editors: [(BoardLiveEditorSession, WKWebView, QuietWindow)] = []
        for board in store.boards.sorted(by: { $0.markdown.count > $1.markdown.count }).prefix(BoardNavigation.liveEditorLimit) {
            let session = BoardLiveEditorSession(store: store, board: board, defaults: InMemoryDefaults())
            let webView = session.makeWebView()
            session.configure(fontSize: 13, dark: true, previewOnly: true)
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.orderBack(nil)
            for _ in 0..<100 where !session.ready { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            editors.append((session, webView, window))
            report("board editor \(editors.count) (\(board.markdown.count) chars)")
            print(String(format: "PROBE   web content processes %.1f MB", webFootprint(editors.map(\.1))))
        }

        // 窗口隐藏（应用里关窗口只是隐藏）：内容和图层还在不在。
        notes.orderOut(nil)
        main.orderOut(nil)
        editors.forEach { $0.2.orderOut(nil) }
        report("all windows hidden")
        notes.contentView = nil
        main.contentView = nil
        editors.forEach { $0.2.contentView = nil }
        editors.removeAll()
        report("window contents released")
    }

    /// WebKit 内容进程的物理占用（去重后求和）。
    private func webFootprint(_ views: [WKWebView]) -> Double {
        let pids = Set(views.compactMap { ($0.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value }.filter { $0 > 0 })
        return pids.reduce(0) { total, pid in
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            return total + (result == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : 0)
        }
    }
}
