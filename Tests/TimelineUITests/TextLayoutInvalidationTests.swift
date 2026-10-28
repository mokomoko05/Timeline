import AppKit
import XCTest
@testable import Timeline

@MainActor
final class TextLayoutInvalidationTests: XCTestCase {
    private func textView() throws -> InteractiveTaskText {
        let view = InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        view.isEditable = false
        view.isVerticallyResizable = false
        view.textContainerInset = NSSize(width: 2, height: 0)
        let container = try XCTUnwrap(view.textContainer)
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(TaskLinkText.styledText(
            Array(repeating: "中文记录和需要换行的长内容 [链接](https://example.com)", count: 8).joined(separator: " "),
            completed: false, color: .labelColor, fontSize: 13))
        view.setFrameSize(view.frame.size)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testUnchangedFrameDoesNotInvalidateSettledTextLayout() throws {
        let view = try textView()
        view.needsLayout = false
        let selection = NSRange(location: 3, length: 5)
        view.setSelectedRange(selection)
        for _ in 0..<100 {
            view.setFrameSize(view.frame.size)
            XCTAssertFalse(view.needsLayout)
        }
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertFalse(view.linkRegions().isEmpty)
    }

    func testUnchangedFramePreservesPendingContentLayout() throws {
        let view = try textView()
        view.needsLayout = true
        view.setFrameSize(view.frame.size)
        XCTAssertTrue(view.needsLayout)
    }

    func testUnchangedFrameSynchronizesChangedTextInsets() throws {
        let view = try textView()
        view.textContainerInset = NSSize(width: 18, height: 0)
        view.setFrameSize(view.frame.size)
        XCTAssertEqual(try XCTUnwrap(view.textContainer).containerSize.width, 284, accuracy: 0.001)
    }

    func testWidthChangesReflowTextAndHeightChangesPreserveTextWidth() throws {
        let view = try textView()
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let originalHeight = manager.usedRect(for: container).height
        view.setFrameSize(NSSize(width: 160, height: 200))
        manager.ensureLayout(for: container)
        XCTAssertEqual(container.containerSize.width, 156, accuracy: 0.001)
        let narrowHeight = manager.usedRect(for: container).height
        XCTAssertGreaterThan(narrowHeight, originalHeight)
        view.setFrameSize(NSSize(width: 160, height: 400))
        manager.ensureLayout(for: container)
        XCTAssertEqual(view.frame.height, 400, accuracy: 0.001)
        XCTAssertEqual(container.containerSize.width, 156, accuracy: 0.001)
        XCTAssertEqual(manager.usedRect(for: container).height, narrowHeight, accuracy: 0.001)
        view.setFrameSize(NSSize(width: 320, height: 200))
        manager.ensureLayout(for: container)
        XCTAssertEqual(manager.usedRect(for: container).height, originalHeight, accuracy: 0.001)
    }

    func testWideFormulaScrollStripFollowsWidthChanges() throws {
        let view = try textView()
        view.markdown = true
        let formula = Array(repeating: "x", count: 45).joined(separator: "+")
        view.textStorage?.setAttributedString(MarkdownText.render("$$\n" + formula + "\n$$", color: .labelColor, fontSize: 13))
        view.setFrameSize(NSSize(width: 160, height: 200))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.subviews.compactMap { $0 as? NSScrollView }.count, 1)
        view.setFrameSize(NSSize(width: 2400, height: 200))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.subviews.compactMap { $0 as? NSScrollView }.isEmpty)
        view.setFrameSize(NSSize(width: 160, height: 200))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.subviews.compactMap { $0 as? NSScrollView }.count, 1)
    }
}
