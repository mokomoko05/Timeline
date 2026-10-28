import AppKit
import SwiftUI
import XCTest
@testable import Timeline

@MainActor
final class TextLayoutReuseTests: XCTestCase {
    private func host(_ source: String) -> NSHostingView<some View> {
        let view = TaskLinkText(source: source, completed: false, color: .primary, fontSize: 13,
                                edit: {}, open: { _ in }, maxLines: 0, markdown: true, compactLines: true)
            .environment(\.typography, AppTypography(scale: 1.1, lineSpacing: 0))
            .frame(width: 420).fixedSize(horizontal: false, vertical: true)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func text(in view: NSView) -> InteractiveTaskText? {
        (view as? InteractiveTaskText) ?? view.subviews.lazy.compactMap { self.text(in: $0) }.first
    }

    func testRecreatedMarkdownRowsReuseHeightsWithoutPreparingAnotherTextKitStack() throws {
        let source = "## \(UUID().uuidString)\n\n" + String(repeating: "中文长笔记，验证滚回同一行后的换行和高度。", count: 30)
            + "\n\n[Link](https://example.com)"
        let originalHost = host(source)
        let original = try XCTUnwrap(text(in: originalHost))
        XCTAssertNotNil(original.measurer)
        let recreatedHost = host(source)
        let recreated = try XCTUnwrap(text(in: recreatedHost))
        XCTAssertTrue(original.rendered === recreated.rendered)
        XCTAssertEqual(original.frame.height, recreated.frame.height, accuracy: 0.1)
        XCTAssertEqual(original.string, recreated.string)
        XCTAssertEqual(recreated.linkRegions().first?.url.absoluteString, "https://example.com")
        XCTAssertNil(recreated.measurer, "滚回已有高度缓存的行时不应再分配测量栈")
    }

    func testCacheMissAfterResizeCreatesOneMeasurerAndContentChangesStillRemeasure() throws {
        let source = "## \(UUID().uuidString)\n\n" + String(repeating: "文字换行 Text layout ", count: 40)
        let originalHost = host(source)
        let original = try XCTUnwrap(text(in: originalHost))
        let recreatedHost = host(source)
        let recreated = try XCTUnwrap(text(in: recreatedHost))
        let width = original.frame.width - original.textContainerInset.width * 2
        let wide = recreated.measuredHeight(forWidth: width, maxLines: 0)
        XCTAssertNil(recreated.measurer)
        let narrow = recreated.measuredHeight(forWidth: 113, maxLines: 0)
        XCTAssertGreaterThan(narrow, wide)
        let prepared = try XCTUnwrap(recreated.measurer)
        XCTAssertEqual(recreated.measuredHeight(forWidth: width, maxLines: 0), wide)
        XCTAssertTrue(recreated.measurer === prepared)
        let replacement = TextRenderCache.Entry(MarkdownText.render("A short replacement", color: .labelColor, fontSize: 13))
        recreated.rendered = replacement
        let replacedHeight = recreated.measuredHeight(forWidth: 113, maxLines: 0)
        XCTAssertLessThan(replacedHeight, narrow)
        XCTAssertTrue(recreated.measurer === prepared)
        XCTAssertTrue(recreated.measuredText === replacement)
    }

    func testCachedHeightConstructionCost() throws {
        let originalHost = host("## \(UUID().uuidString)\n\n" + String(repeating: "Long note 测试内容。", count: 80))
        let original = try XCTUnwrap(text(in: originalHost))
        let entry = try XCTUnwrap(original.rendered)
        let width = original.frame.width - original.textContainerInset.width * 2
        let expected = original.measuredHeight(forWidth: width, maxLines: 0)
        let started = CFAbsoluteTimeGetCurrent()
        var prepared = 0
        for _ in 0..<100 {
            autoreleasepool {
                let view = InteractiveTaskText()
                view.rendered = entry
                XCTAssertEqual(view.measuredHeight(forWidth: width, maxLines: 0), expected)
                if view.measurer != nil { prepared += 1 }
            }
        }
        print("LAYOUT REUSE cached rows=100 prepared=\(prepared) constructionMS=\((CFAbsoluteTimeGetCurrent() - started) * 1000)")
        XCTAssertEqual(prepared, 0)
    }
}
