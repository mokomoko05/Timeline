import AppKit
import SwiftUI
import WebKit
import XCTest
import TimelineCore
@testable import Timeline

/// 同一条同时出现在两页里（笔记窗口的笔记页和日记页一直都在，专注时记的笔记两边都有）：
/// 在显示着的那页编辑时，编辑器挂在这一页，不会被隐藏的那页抢走（那样这边正文隐去、编辑器又看不见，整条空白）。
@MainActor
final class FocusNoteInlineEditTests: XCTestCase {
    private func wait(_ timeout: Duration = .seconds(8), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等待超时")
    }

    func testEditorStaysOnTheVisiblePageWhenTheEntryIsAlsoOnAHiddenOne() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = JournalDates.calendar.startOfDay(for: Date())
        _ = try store.quickLogEntry("专注时记的笔记", linkDefault: false, on: date, focusEvent: .note)
        let log = try XCTUnwrap(store.entry(for: date).logs.first)
        let editor = InlineMarkdownEditor.shared
        func page() -> NSHostingView<AnyView> {
            let view = NSHostingView(rootView: AnyView(VStack(alignment: .leading, spacing: 0) {
                EditableLogText(log: log, editable: true, begin: { point, prepare in
                    editor.begin(log, on: date, store: store, at: point, fontSize: 13, lineSpacing: 2, dark: false, prepare: prepare)
                }) { editAt in
                    TaskLinkText(source: log.text, completed: false, color: Palette.ink, fontSize: 13, edit: {}, open: { _ in },
                                 maxLines: 0, markdown: true, compactLines: true, editAt: editAt)
                }
                Spacer(minLength: 0)
            }.frame(width: 420, height: 300, alignment: .top)))
            view.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
            return view
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        let window = QuietWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFront(nil)
        defer { editor.finish(); window.contentView = nil; window.close() }

        // 显示着的一页在前、隐藏的一页在后（后建的那页以前会把编辑器拿走）。
        let visible = page(), hidden = page()
        hidden.isHidden = true
        root.addSubview(visible)
        root.addSubview(hidden)
        visible.layoutSubtreeIfNeeded(); hidden.layoutSubtreeIfNeeded()

        let webViewForTest = editor.makeWebView()
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        if webViewForTest.responds(to: selector) {
            unsafeBitCast(webViewForTest.method(for: selector), to: Setter.self)(webViewForTest, selector, false)
        }
        defer {
            if webViewForTest.responds(to: selector) {
                unsafeBitCast(webViewForTest.method(for: selector), to: Setter.self)(webViewForTest, selector, true)
            }
        }

        for round in 0..<3 {
            editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
            try await wait { visible.layoutSubtreeIfNeeded(); hidden.layoutSubtreeIfNeeded(); return editor.height != nil }
            visible.layoutSubtreeIfNeeded(); hidden.layoutSubtreeIfNeeded()
            let webView = try XCTUnwrap(editor.webView)
            XCTAssertTrue(webView.isDescendant(of: visible), "第 \(round) 次：编辑器挂在显示着的那页")
            XCTAssertFalse(webView.isHiddenOrHasHiddenAncestor, "第 \(round) 次：编辑器看得见")
            let text = try await webView.evaluateJavaScript("document.querySelector('.cm-content').textContent") as? String
            XCTAssertEqual(text, "专注时记的笔记")
            editor.finish()
            visible.layoutSubtreeIfNeeded(); hidden.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }

        // 换页：原来隐藏的那页显示出来，在那边编辑，编辑器跟过去。
        visible.isHidden = true
        hidden.isHidden = false
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        try await wait { visible.layoutSubtreeIfNeeded(); hidden.layoutSubtreeIfNeeded(); return editor.height != nil }
        XCTAssertTrue(try XCTUnwrap(editor.webView).isDescendant(of: hidden), "换页后编辑器挂在新显示的那页")
    }
}
