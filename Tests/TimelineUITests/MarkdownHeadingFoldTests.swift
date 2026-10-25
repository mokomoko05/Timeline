import AppKit
import XCTest
@testable import Timeline

/// 笔记里的 Markdown 标题和工作板一样可以折叠：收起到下一个同级或更高级标题为止，点整行标题切换，状态按笔记记住。
@MainActor
final class MarkdownHeadingFoldTests: XCTestCase {
    private let source = "# A\n\nalpha\n\n## A1\n\ninside\n\n# B\n\nbeta\n\n# Empty\n# A\n\nagain"

    private func render(_ folds: Set<String>?) -> NSAttributedString {
        MarkdownText.render(source, color: .labelColor, fontSize: 13, folds: folds)
    }

    private func keys(_ text: NSAttributedString) -> [String] {
        var result: [String] = []
        text.enumerateAttribute(MarkdownText.headingFoldKey, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let key = value as? String { result.append(key) }
        }
        return result
    }

    func testOnlyHeadingsWithContentAreFoldableAndKeysMatchTheBoard() {
        XCTAssertEqual(keys(render([])), ["h1:A#0", "h2:A1#0", "h1:B#0", "h1:A#1"], "没有内容的标题不能折叠；同名标题按次序编号")
        XCTAssertTrue(keys(render(nil)).isEmpty, "没有折叠标识时和以前一样")
    }

    func testFoldingHidesTheSectionUpToTheNextHeadingOfTheSameLevel() {
        let folded = render(["h1:A#0"]).string
        XCTAssertFalse(folded.contains("alpha") || folded.contains("inside") || folded.contains("A1"), "A 下面（含 A1 一节）都收起")
        XCTAssertTrue(folded.contains("beta") && folded.contains("again"))
        XCTAssertTrue(folded.contains("⋯"))
        let inner = render(["h2:A1#0"]).string
        XCTAssertTrue(inner.contains("alpha") && !inner.contains("inside") && inner.contains("beta"))
    }

    func testClickingAnywhereOnTheHeadingLineTogglesAndIsRememberedPerNote() {
        let defaults = InMemoryDefaults()
        let previous = HeadingFolds.defaults
        HeadingFolds.defaults = defaults
        defer { HeadingFolds.defaults = previous }

        let view = InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        view.markdown = true
        var toggled: [String] = []
        view.onToggleHeading = { key in toggled.append(key); HeadingFolds.toggle(key, in: "log.1") }
        view.textStorage?.setAttributedString(render([]))
        let regions = view.headingRegions()
        let first = try? XCTUnwrap(regions.first { $0.key == "h1:A#0" })
        XCTAssertNotNil(first)
        if let first {
            XCTAssertGreaterThan(first.rect.width, 300, "整行都能点，不只是左边的箭头")
            XCTAssertEqual(view.headingKey(at: NSPoint(x: first.rect.maxX - 10, y: first.rect.midY)), "h1:A#0")
        }
        if let path = ProcessInfo.processInfo.environment["TIMELINE_NOTE_FOLD_SNAPSHOT"] {
            view.textStorage?.setAttributedString(render(["h2:A1#0"]))
            view.appearance = NSAppearance(named: .darkAqua)
            view.drawsBackground = true
            view.backgroundColor = .windowBackgroundColor
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        view.onToggleHeading?("h1:A#0")
        XCTAssertEqual(HeadingFolds.folded(in: "log.1"), ["h1:A#0"])
        XCTAssertTrue(HeadingFolds.folded(in: "log.2").isEmpty, "按笔记分别记住")
        view.onToggleHeading?("h1:A#0")
        XCTAssertNil(defaults.object(forKey: HeadingFolds.key("log.1")), "展开后不再记录")
    }
}
