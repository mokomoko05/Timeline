import AppKit
import XCTest
@testable import Timeline

private final class RegionLayoutManager: NSLayoutManager {
    var glyphRangeQueries = 0

    override func glyphRange(forCharacterRange charRange: NSRange, actualCharacterRange actualCharRange: NSRangePointer?) -> NSRange {
        glyphRangeQueries += 1
        return super.glyphRange(forCharacterRange: charRange, actualCharacterRange: actualCharRange)
    }
}

@MainActor
final class TextRegionCacheTests: XCTestCase {
    private func textView(height: CGFloat = 600) -> (InteractiveTaskText, RegionLayoutManager) {
        let storage = NSTextStorage()
        let manager = RegionLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 396, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let view = InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 400, height: height), textContainer: container)
        withExtendedLifetime(storage) {}
        view.isEditable = false
        view.isVerticallyResizable = false
        view.markdown = true
        view.onToggleHeading = { _ in }
        view.textContainerInset = NSSize(width: 2, height: 0)
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        storage.setAttributedString(MarkdownText.render("# Heading\n\n[Link](https://example.com)\n\n- [ ] Task\n\n```swift\nlet value = 1\n```",
                                                       color: .labelColor, fontSize: 13, interactiveTasks: true, folds: []))
        return (view, manager)
    }

    func testRepeatedDrawingAndHitTestingReuseInteractionGeometry() throws {
        let (view, manager) = textView()
        XCTAssertFalse(view.linkRegions().isEmpty)
        XCTAssertFalse(view.taskRegions().isEmpty)
        XCTAssertFalse(view.codeRegions().isEmpty)
        XCTAssertFalse(view.headingRegions().isEmpty)
        let queries = manager.glyphRangeQueries
        XCTAssertGreaterThan(queries, 0)
        for _ in 0..<30 {
            _ = view.linkRegions()
            _ = view.taskRegions()
            _ = view.codeRegions()
            _ = view.headingRegions()
        }
        XCTAssertEqual(manager.glyphRangeQueries, queries)
    }

    func testAttributeChangesWithoutTextChangesRefreshLinks() throws {
        let (view, _) = textView()
        let original = try XCTUnwrap(view.linkRegions().first)
        let storage = try XCTUnwrap(view.textStorage)
        let range = (storage.string as NSString).range(of: "Link")
        let replacement = try XCTUnwrap(URL(string: "https://example.org"))
        storage.addAttribute(.link, value: replacement, range: range)
        let changed = try XCTUnwrap(view.linkRegions().first)
        XCTAssertEqual(changed.url, replacement)
        XCTAssertEqual(changed.rect, original.rect)
        storage.removeAttribute(.link, range: range)
        XCTAssertTrue(view.linkRegions().isEmpty)
    }

    func testReplacingContentRefreshesEveryRegionType() throws {
        let (view, _) = textView()
        _ = view.linkRegions()
        _ = view.taskRegions()
        _ = view.codeRegions()
        _ = view.headingRegions()
        view.textStorage?.setAttributedString(MarkdownText.render("# Changed\n\nPlain text", color: .labelColor, fontSize: 13, folds: []))
        XCTAssertTrue(view.linkRegions().isEmpty)
        XCTAssertTrue(view.taskRegions().isEmpty)
        XCTAssertTrue(view.codeRegions().isEmpty)
        XCTAssertEqual(view.headingRegions().map(\.key), ["h1:Changed#0"])
    }

    func testResizeAndInsetsMoveInteractionRegions() throws {
        let (view, _) = textView()
        let heading = try XCTUnwrap(view.headingRegions().first)
        let code = try XCTUnwrap(view.codeRegions().first)
        view.setFrameSize(NSSize(width: 240, height: 600))
        let narrowHeading = try XCTUnwrap(view.headingRegions().first)
        let narrowCode = try XCTUnwrap(view.codeRegions().first)
        XCTAssertLessThan(narrowHeading.rect.minX, heading.rect.minX - 100)
        XCTAssertLessThan(narrowCode.copy.minX, code.copy.minX - 100)
        let link = try XCTUnwrap(view.linkRegions().first)
        view.textContainerInset = NSSize(width: 18, height: 12)
        view.setFrameSize(view.frame.size)
        let shiftedLink = try XCTUnwrap(view.linkRegions().first)
        XCTAssertEqual(shiftedLink.rect.minX, view.textContainerOrigin.x - 3, accuracy: 0.1)
        XCTAssertEqual(shiftedLink.rect.minY - link.rect.minY, 12, accuracy: 0.1)
    }

    func testHeightChangesRefreshClippedLinkRegions() throws {
        let (view, _) = textView(height: 20)
        XCTAssertTrue(view.linkRegions().isEmpty)
        view.setFrameSize(NSSize(width: 400, height: 600))
        XCTAssertFalse(view.linkRegions().isEmpty)
    }

    func testRegionCachingDoesNotRetainTextViews() async throws {
        weak var releasedView: InteractiveTaskText?
        autoreleasepool {
            let view = InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
            view.markdown = true
            view.onToggleHeading = { _ in }
            view.textStorage?.setAttributedString(MarkdownText.render("# Heading\n\n[Link](https://example.com)\n\n```\ncode\n```",
                                                                      color: .labelColor, fontSize: 13, folds: []))
            let window = QuietWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            releasedView = view
            _ = view.linkRegions()
            _ = view.codeRegions()
            _ = view.headingRegions()
            window.contentView = nil
            window.close()
        }
        for _ in 0..<100 {
            if autoreleasepool(invoking: { releasedView == nil }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(releasedView)
    }
}
