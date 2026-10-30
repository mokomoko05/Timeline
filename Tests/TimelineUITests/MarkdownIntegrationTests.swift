import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class MarkdownIntegrationTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    func testNativeTextViewHasAWorkingTextKitStackAndDrawsItsContent() throws {
        _ = NSApplication.shared
        let view = InteractiveTaskText()
        let storage = try XCTUnwrap(view.textStorage, "Task and note text must have a backing text storage")
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        view.setFrameSize(NSSize(width: 300, height: 60))
        view.drawsBackground = true
        view.backgroundColor = .white
        storage.setAttributedString(NSAttributedString(string: "Visible 文字", attributes: [
            .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black
        ]))
        manager.ensureLayout(for: container)
        XCTAssertEqual(view.string, "Visible 文字")
        XCTAssertGreaterThan(manager.numberOfGlyphs, 0)
        XCTAssertGreaterThan(manager.usedRect(for: container).width, 30)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var inkPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.alphaComponent > 0.5, max(color.redComponent, color.greenComponent, color.blueComponent) < 0.5 {
                    inkPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(inkPixels, 40, "The view must paint visible glyphs, not just reserve layout space")
    }

    func testNotesAndLogsRenderMarkdownAndKeepSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day = Date()
        let task = try XCTUnwrap(store.addParsedTodo("Markdown 显示验证", on: day))
        let source = """
        ## 项目进展

        **重点**、*备注*、~~旧计划~~ 和 `inline code`

        | 项目 | 状态 | 数量 |
        | :--- | :---: | ---: |
        | 笔记 Markdown | **完成** | 12 |
        | 日志表格 | [说明](https://example.com) | 8 |
        | 中文换行 | 一段较长的中文说明，会随窗口宽度自动换行 | 100 |

        - [x] 表格排版
        - [ ] 后续计划

        > 引用：保留原文，阅读时自动排版。

        ```swift
        let message = "Hello Markdown"
        print(message)
        ```
        """
        _ = try store.quickLog(source, taskID: task.id, on: day)
        let views: [(String, AnyView)] = [
            ("notes", AnyView(NotesView(store: store, initialSelection: task.id, reveal: { _ in }, openDay: { _ in }))),
            ("logs", AnyView(UnifiedJournalView(store: store, workspace: NotesWorkspaceNavigation(date: day))))
        ]
        func textViews(_ view: NSView) -> [InteractiveTaskText] {
            (view as? InteractiveTaskText).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        for (name, root) in views {
            let host = NSHostingView(rootView: root.frame(width: 1100, height: 850))
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            Self.keepAlive += [window, host]
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let body = try XCTUnwrap(textViews(host).first { $0.source == source }, name)
            XCTAssertTrue(body.markdown, name)
            XCTAssertTrue(body.string.contains("项目进展"), name)
            XCTAssertFalse(body.string.contains("| :---"), name)
            XCTAssertGreaterThan(body.frame.height, 250, name)
            if let destination = ProcessInfo.processInfo.environment["TIMELINE_MARKDOWN_SNAPSHOTS"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
            }
            window.close()
        }
        XCTAssertEqual(store.entry(for: day).logs.first?.text, source)
    }
}
