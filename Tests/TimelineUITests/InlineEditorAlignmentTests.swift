import AppKit
import SwiftUI
import WebKit
import XCTest
import TimelineCore
@testable import Timeline

/// 点进日志就地编辑时文字不挪位置：编辑器里每一行的位置、整条的高度和渲染好的正文（MarkdownText）一致，
/// 正文和编辑器之间切换时编辑器一直挂在同一个容器里（换容器会白一下，还可能整块不见）。
@MainActor
final class InlineEditorAlignmentTests: XCTestCase {
    private func wait(_ timeout: Duration = .seconds(8), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等待超时")
    }

    private func find(_ view: NSView) -> InteractiveTaskText? {
        if let text = view as? InteractiveTaskText { return text }
        for child in view.subviews { if let found = find(child) { return found } }
        return nil
    }

    func testEditorLinesUpWithRenderedText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = Date()
        let text = """
        今天把就地编辑的对齐做完了，这一段故意写得很长很长，让它在四百多像素宽的地方折成两到三行，看看折行之后的位置。

        ## Heading

        1. 第一步
        2. 第二步
           - 嵌套的一项

        - [ ] 没做完的事
        - [x] 做完的事

        > 引用的一段话
        > 第二行

        ```python
        def f(x):
            return x * 2  # double
        ```

        末尾。
        """
        store.setLogDraft(text, on: date)
        _ = try store.commitLog(on: date, linkDefault: false)
        let log = try XCTUnwrap(store.entry(for: date).logs.first)
        let editor = InlineMarkdownEditor.shared
        let root = VStack(alignment: .leading, spacing: 0) {
            EditableLogText(log: log, editable: true, begin: { _ in }) { editAt in
                TaskLinkText(source: log.text, completed: false, color: Palette.ink, fontSize: 13, edit: {}, open: { _ in },
                             maxLines: 0, markdown: true, compactLines: true, editAt: editAt)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 420, height: 600, alignment: .top)
        let host = NSHostingView(rootView: root)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { editor.finish(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()

        // 原生正文里每一行（段落的第一个行片段）的位置。
        let native = try XCTUnwrap(find(host))
        let manager = try XCTUnwrap(native.layoutManager), storage = try XCTUnwrap(native.textStorage)
        var nativeTops: [String: CGFloat] = [:]
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: native.textContainer!)) { rect, used, _, glyphs, _ in
            let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let line = (storage.string as NSString).substring(with: chars).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = String(line.drop { "•\u{FFFC}0123456789.\t ".contains($0) }.prefix(4))
            if !key.isEmpty, nativeTops[key] == nil { nativeTops[key] = native.convert(NSPoint(x: 0, y: rect.minY), to: host).y }
        }
        let nativeHeight = native.frame.height

        // 测试窗口透明度是 0，WebKit 当它被挡住、不跑动画帧；让它照常画（和真的显示在屏幕上一样）。
        let webViewForTest = editor.makeWebView()
        func occlusionDetection(_ enabled: Bool) {
            let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            guard webViewForTest.responds(to: selector) else { return }
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webViewForTest.method(for: selector), to: Setter.self)(webViewForTest, selector, enabled)
        }
        occlusionDetection(false)
        defer { occlusionDetection(true) }
        let started = ContinuousClock.now
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: true)
        host.layoutSubtreeIfNeeded()
        let container = try XCTUnwrap(editor.webView?.superview, "开始编辑时编辑器先悄悄挂到这一条上")
        XCTAssertEqual(native.alphaValue, 1)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        print("INLINE reveal after", ContinuousClock.now - started)
        host.layoutSubtreeIfNeeded()
        let webView = try XCTUnwrap(editor.webView)
        // 换过来的时候网页已经画过这次的内容：原生正文藏起来的那一帧，编辑器已经在屏幕上（不会空一帧、闪一下）。
        let frames = try await webView.evaluateJavaScript("window.boardEditor.paintedFrames || 0") as? Int
        XCTAssertGreaterThanOrEqual(frames ?? 0, 1, "网页画好之后才换")
        XCTAssertTrue(webView.superview === container, "显出来时没有换容器")
        XCTAssertEqual(editor.height ?? 0, nativeHeight, accuracy: 1, "编辑器和正文一样高：下面的内容不跳")

        let json = try await webView.evaluateJavaScript("""
        JSON.stringify([...document.querySelectorAll('.cm-line')].map(l => [l.getBoundingClientRect().top, l.textContent,
          l.classList.contains('cm-quote') ? parseFloat(getComputedStyle(l).paddingTop) : 0]))
        """) as? String
        let lines = try JSONSerialization.jsonObject(with: Data((json ?? "[]").utf8)) as? [[Any]] ?? []
        let shift = CGFloat(InlineEditorMetrics.css(fontSize: 13, lineSpacing: 2)["shift"] ?? 0)
        var compared = 0
        for line in lines {
            guard let top = line[0] as? Double, let content = line[1] as? String, let pad = line[2] as? Double else { continue }
            let key = String(content.trimmingCharacters(in: .whitespaces).drop { "•0123456789.".contains($0) }.prefix(4))
            guard !key.isEmpty, let expected = nativeTops[key], !content.hasPrefix("```") else { continue }
            // 引用块上面的空在原生里不算在行片段里，网页里是第一行的上内边距：比文字所在的位置。
            let webTop = CGFloat(top) + shift + CGFloat(pad)
            XCTAssertEqual(webTop, expected, accuracy: 1, "「\(content)」的位置和正文一致")
            compared += 1
        }
        XCTAssertGreaterThanOrEqual(compared, 9, "比较了大部分行")

        // 第二次点（网页已经加载好，平时都是这种）：从点下去到换成编辑器只等网页画两帧。
        editor.finish()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let again = ContinuousClock.now
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: true)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.height != nil }
        print("INLINE warm reveal after", ContinuousClock.now - again)
    }
}
