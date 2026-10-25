import AppKit
import Darwin
import SwiftUI
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
        notes.contentView = nil
        main.contentView = nil
    }
}
