import AppKit
import XCTest
@testable import Timeline

final class TaskLinkTextTests: XCTestCase {
    @MainActor
    func testLinkCapsulePaddingOpensURLWithoutHittingTextGlyphs() async throws {
        let view = InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
        view.textContainerInset = NSSize(width: 5, height: 4)
        let container = try XCTUnwrap(view.textContainer)
        container.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(TaskLinkText.styledText("[论文](file:///tmp/paper.pdf) 和 [网站](https://example.com)",
                                                                     completed: false, color: .labelColor, fontSize: 13))
        let regions = view.linkRegions()
        XCTAssertEqual(regions.count, 2)
        let paper = try XCTUnwrap(regions.first)
        let paddedPoint = NSPoint(x: paper.rect.minX + 0.5, y: paper.rect.midY)
        let manager = try XCTUnwrap(view.layoutManager)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: 0, length: 2), actualCharacterRange: nil)
        let textRect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        XCTAssertFalse(textRect.contains(paddedPoint))
        var opened: URL?
        view.onOpen = { opened = $0 }
        view.activate(at: paddedPoint)
        XCTAssertEqual(opened, URL(string: "file:///tmp/paper.pdf"))
        XCTAssertEqual(view.link(at: NSPoint(x: regions[1].rect.midX, y: regions[1].rect.midY)), URL(string: "https://example.com"))
        XCTAssertNil(view.link(at: NSPoint(x: 270, y: 50)))
    }

    @MainActor
    func testTruncatedHiddenLinksHaveNoClickableCapsule() async throws {
        let view = InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
        let container = try XCTUnwrap(view.textContainer)
        container.widthTracksTextView = false
        container.containerSize = NSSize(width: 70, height: 200)
        container.maximumNumberOfLines = 1
        container.lineBreakMode = .byTruncatingTail
        view.textStorage?.setAttributedString(TaskLinkText.styledText("这里是一段很长很长的普通文字 [隐藏链接](https://example.com)",
                                                                     completed: false, color: .labelColor, fontSize: 13))
        XCTAssertTrue(view.linkRegions().isEmpty)
    }

    @MainActor
    func testAbbreviatedCalendarNameRetainsNativeLinkAndCompletionStyle() async throws {
        let text = TaskLinkText.styledText("阅读 [论文](file:///tmp/paper.pdf) 并做笔记", completed: true,
                                           color: .secondaryLabelColor, fontSize: 10, displayName: "EuroSys")
        XCTAssertEqual(text.string, "EuroSys")
        let attributes = text.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(attributes[.link] as? URL, URL(string: "file:///tmp/paper.pdf"))
        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, NativePalette.accent, "链接用主题强调色")
        XCTAssertEqual(attributes[.underlineStyle] as? Int, 1)
        XCTAssertEqual(attributes[.strikethroughStyle] as? Int, 1)
        XCTAssertEqual((attributes[.font] as? NSFont)?.pointSize, 10)
    }

    @MainActor
    func testRenderedAliasHasNativeURLBlueUnderlineAndPointer() async throws {
        let text = TaskLinkText.styledText("阅读 [论文](https://arxiv.org)", completed: false, color: .labelColor, fontSize: 13)
        XCTAssertEqual(text.string, "阅读 论文")
        let range = (text.string as NSString).range(of: "论文")
        let attributes = text.attributes(at: range.location, effectiveRange: nil)
        XCTAssertEqual(attributes[.link] as? URL, URL(string: "https://arxiv.org"))
        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, NativePalette.accent, "链接用主题强调色")
        XCTAssertEqual(attributes[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(attributes[.cursor] as? NSCursor, .pointingHand)
        XCTAssertNil(text.attribute(.link, at: 0, effectiveRange: nil))
    }

    @MainActor
    func testCompletedLinkRetainsURLAndAddsStrikethrough() async throws {
        let text = TaskLinkText.styledText("[论文](https://arxiv.org)", completed: true, color: .secondaryLabelColor, fontSize: 12)
        XCTAssertNotNil(text.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertEqual(text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int, 1)
        XCTAssertEqual(text.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, 1)
    }

    @MainActor
    func testNativeSingleClickOpensURLAndOnlyDoubleClickEntersEditing() async throws {
        let view = InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 240, height: 70))
        view.textContainerInset = .zero
        let container = try XCTUnwrap(view.textContainer)
        container.lineFragmentPadding = 0
        container.containerSize = NSSize(width: 240, height: 200)
        view.textStorage?.setAttributedString(TaskLinkText.styledText("阅读 [论文](https://arxiv.org)", completed: false, color: .labelColor, fontSize: 13))
        let manager = try XCTUnwrap(view.layoutManager)
        manager.ensureLayout(for: container)
        let range = (view.string as NSString).range(of: "论文")
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        let linkPoint = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        var opened: [URL] = []
        var edits = 0
        view.onOpen = { opened.append($0) }
        view.onEdit = { edits += 1 }
        view.activate(at: linkPoint)
        XCTAssertEqual(opened, [URL(string: "https://arxiv.org")!])
        XCTAssertEqual(edits, 0)
        view.activate(at: NSPoint(x: 220, y: 50))
        XCTAssertEqual(edits, 0)
        view.activate(at: NSPoint(x: 220, y: 50), clickCount: 2)
        XCTAssertEqual(edits, 1)
        view.activate(at: linkPoint, clickCount: 2)
        XCTAssertEqual(edits, 2)
        view.interactionEnabled = false
        view.activate(at: linkPoint)
        XCTAssertEqual(opened.count, 1)
    }
}

@MainActor
final class TextContextMenuTests: XCTestCase {
    private func event() -> NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testMenuIsBuiltFromItemsWithSeparatorsAndFiresActions() throws {
        var fired: [String] = []
        let menu = NSMenu.make([
            TextMenuItem(title: "复制", symbol: "doc.on.doc", action: { fired.append("copy") }),
            .divider,
            TextMenuItem(title: "删除", symbol: "trash", destructive: true, action: { fired.append("delete") }),
        ])
        XCTAssertEqual(menu.items.map(\.title), ["复制", "", "删除"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertNotNil(menu.items[0].image)
        for item in [menu.items[0], menu.items[2]] {
            let target = try XCTUnwrap(item.target)
            _ = target.perform(item.action)
        }
        XCTAssertEqual(fired, ["copy", "delete"])
    }

    func testTextViewUsesCustomMenuOnlyWhenItemsAreGivenAndAddsCopyForASelection() {
        let view = InteractiveTaskText()
        view.string = "一段日志文字"
        XCTAssertNil(view.menu(for: event()), "没有自定义操作时保持原来的行为：没有右键菜单")
        view.menuItems = [TextMenuItem(title: "编辑", action: {}), TextMenuItem(title: "删除", destructive: true, action: {})]
        XCTAssertEqual(view.menu(for: event())?.items.map(\.title), ["编辑", "删除"])
        view.setSelectedRange(NSRange(location: 0, length: 2))
        XCTAssertEqual(view.menu(for: event())?.items.map(\.title), ["拷贝所选文字", "", "编辑", "删除"], "选中了文字就多一项拷贝")
    }
}
