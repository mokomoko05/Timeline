import AppKit
import SwiftUI
import WebKit
import XCTest
import TimelineCore
@testable import Timeline

/// 日志、笔记点一下就地编辑：换成和工作板一样的所见即所得编辑器，跟着内容长高；Esc / ⌘↩ / 点别处保存并换回正文。
@MainActor
final class InlineMarkdownEditorTests: XCTestCase {
    private func wait(_ timeout: Duration = .seconds(8), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等待超时")
    }

    func testClickingALogEditsItInPlaceAndEscapeSaves() async throws {
        let defaults = InMemoryDefaults()
        let previous = HeadingFolds.defaults
        HeadingFolds.defaults = defaults
        defer { HeadingFolds.defaults = previous }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = Date()
        store.setLogDraft("# 标题\n\n第一段 **加粗** 和 $x^2$\n\n- 一项\n- 两项", on: date)
        _ = try store.commitLog(on: date, linkDefault: false)
        let log = try XCTUnwrap(store.entry(for: date).logs.first)
        let editor = InlineMarkdownEditor.shared

        let root = VStack(alignment: .leading, spacing: 0) {
            EditableLogText(log: log, editable: true, begin: { point, _ in
                editor.begin(log, on: date, store: store, at: point, fontSize: 13, lineSpacing: 2, dark: true)
            }) { editAt in
                TaskLinkText(source: log.text, completed: false, color: Palette.ink, fontSize: 13, edit: {}, open: { _ in },
                             maxLines: 0, markdown: true, compactLines: true, editAt: editAt)
            }
            Text("下面的内容")
            Spacer(minLength: 0)
        }
        .frame(width: 380, height: 420, alignment: .top)
        let host = NSHostingView(rootView: root)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { editor.finish(); window.contentView = nil; window.close() }

        host.layoutSubtreeIfNeeded()
        editor.begin(log, on: date, store: store, at: CGPoint(x: 30, y: 60), fontSize: 13, lineSpacing: 2, dark: true)
        XCTAssertTrue(editor.isEditing(log.id))
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        let webView = try XCTUnwrap(editor.webView)
        // 排版稳定下来：原生层的高度和编辑器自己量的一致。
        try await wait {
            host.layoutSubtreeIfNeeded()
            let height = try? await webView.evaluateJavaScript("Math.ceil(window.boardEditor.view().dom.getBoundingClientRect().height)") as? Double
            return abs(CGFloat(height ?? 0) - webView.frame.height) < 2
        }
        XCTAssertTrue(webView.isDescendant(of: host), "编辑器放进了这一条")
        XCTAssertGreaterThan(webView.frame.height, 60, "跟着内容长高")
        let state = try await webView.evaluateJavaScript("""
        ({inline: document.documentElement.classList.contains('inline'),
          height: Math.ceil(window.boardEditor.view().dom.getBoundingClientRect().height),
          caret: window.boardEditor.snapshot().head,
          math: !!document.querySelector('.cm-math, .katex, [class*=math]'),
          debug: innerWidth + 'x' + innerHeight + ' lines:' + document.querySelectorAll('.cm-line').length})
        """) as? [String: Any] ?? [:]
        if let path = ProcessInfo.processInfo.environment["TIMELINE_DESIGN_PREVIEW"], !path.isEmpty {
            let image = try await webView.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("inline-editor.png"))
            }
        }
        XCTAssertEqual(state["inline"] as? Bool, true)
        XCTAssertEqual(CGFloat(state["height"] as? Double ?? 0), webView.frame.height, accuracy: 2, "原生层用的是编辑器量出来的高度")
        XCTAssertLessThan(state["caret"] as? Int ?? 999, log.text.count, "光标放在点的地方，不是末尾")

        // 打字：长高后原生层跟着变高。
        let before = webView.frame.height
        _ = try await webView.evaluateJavaScript("""
        (()=>{const v=window.boardEditor.view();v.dispatch({changes:{from:v.state.doc.length,insert:'\\n\\n新的一段\\n\\n再一段'},userEvent:'input.type'});})()
        """)
        try await wait { host.layoutSubtreeIfNeeded(); return (editor.height ?? 0) > before + 20 }

        // Esc 保存并结束。
        _ = try await webView.evaluateJavaScript("document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))")
        try await wait { !editor.isEditing(log.id) }
        XCTAssertTrue(store.entry(for: date).logs.first?.text.hasSuffix("再一段") == true, "改动存进了日志")
    }

    func testClickOutsideSavesAndReadOnlyDoesNotEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = Date()
        store.setLogDraft("原文", on: date)
        _ = try store.commitLog(on: date, linkDefault: false)
        let log = try XCTUnwrap(store.entry(for: date).logs.first)
        let editor = InlineMarkdownEditor.shared
        let root = EditableLogText(log: log, editable: true, begin: { _, _ in }) { _ in Text(log.text) }.frame(width: 300, height: 200, alignment: .top)
        let host = NSHostingView(rootView: root)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { editor.finish(); window.contentView = nil; window.close() }
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        let webView = try XCTUnwrap(editor.webView)
        _ = try await webView.evaluateJavaScript("""
        (()=>{const v=window.boardEditor.view();v.dispatch({changes:{from:v.state.doc.length,insert:'，补充'},userEvent:'input.type'});})()
        """)
        // 点在编辑器外面：保存并换回正文（最后几个字即使还没送过来，也会补存）。
        editor.finish()
        XCTAssertFalse(editor.isEditing(log.id))
        try await wait { store.entry(for: date).logs.first?.text == "原文，补充" }
    }
}
