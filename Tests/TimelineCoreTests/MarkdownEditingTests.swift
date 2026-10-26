import XCTest
@testable import TimelineCore

final class MarkdownEditingTests: XCTestCase {
    /// `|` 标出光标，`[` `]` 标出选区；返回去掉标记后的文字和选区。
    private func parse(_ marked: String) -> (String, NSRange) {
        var text = marked
        if let caret = text.range(of: "|") {
            let location = (String(text[..<caret.lowerBound]) as NSString).length
            text.removeSubrange(caret)
            return (text, NSRange(location: location, length: 0))
        }
        let open = text.range(of: "⟦")!
        let start = (String(text[..<open.lowerBound]) as NSString).length
        text.removeSubrange(open)
        let close = text.range(of: "⟧")!
        let end = (String(text[..<close.lowerBound]) as NSString).length
        text.removeSubrange(close)
        return (text, NSRange(location: start, length: end - start))
    }

    private func render(_ edit: MarkdownEdit, on text: String) -> String {
        let result = edit.applied(to: text) as NSString
        if edit.selection.length == 0 {
            return result.replacingCharacters(in: edit.selection, with: "|")
        }
        let selected = result.substring(with: edit.selection)
        return result.replacingCharacters(in: edit.selection, with: "⟦" + selected + "⟧")
    }

    private func check(_ before: String, _ after: String, file: StaticString = #filePath, line: UInt = #line,
                       _ operation: (String, NSRange) -> MarkdownEdit) {
        let (text, selection) = parse(before)
        XCTAssertEqual(render(operation(text, selection), on: text), after, file: file, line: line)
    }

    func testToggleListStyles() {
        check("买|菜", "- 买|菜") { MarkdownEditing.toggle(.bullet, in: $0, selection: $1) }
        check("- 买|菜", "买|菜") { MarkdownEditing.toggle(.bullet, in: $0, selection: $1) }
        check("- 买|菜", "- [ ] 买|菜") { MarkdownEditing.toggle(.task, in: $0, selection: $1) }
        check("⟦一\n二\n\n三⟧", "⟦1. 一\n2. 二\n\n3. 三⟧") { MarkdownEditing.toggle(.numbered, in: $0, selection: $1) }
        check("  - [x] 已|做", "  已|做") { MarkdownEditing.toggle(.task, in: $0, selection: $1) }
        check("开头\n引|用\n结尾", "开头\n> 引|用\n结尾") { MarkdownEditing.toggle(.quote, in: $0, selection: $1) }
        check("|", "- |") { MarkdownEditing.toggle(.bullet, in: $0, selection: $1) }
    }

    func testHeadingCycles() {
        check("标|题", "# 标|题") { MarkdownEditing.cycleHeading(in: $0, selection: $1) }
        check("# 标|题", "## 标|题") { MarkdownEditing.cycleHeading(in: $0, selection: $1) }
        check("### 标|题\n正文", "标|题\n正文") { MarkdownEditing.cycleHeading(in: $0, selection: $1) }
    }

    func testWrapAndUnwrap() {
        check("很⟦重要⟧的事", "很**⟦重要⟧**的事") { MarkdownEditing.wrap("**", in: $0, selection: $1) }
        check("很**⟦重要⟧**的事", "很⟦重要⟧的事") { MarkdownEditing.wrap("**", in: $0, selection: $1) }
        check("很⟦**重要**⟧的事", "很⟦重要⟧的事") { MarkdownEditing.wrap("**", in: $0, selection: $1) }
        check("a|b", "a`|`b") { MarkdownEditing.wrap("`", in: $0, selection: $1) }
        // 加粗里面再加斜体，不会把加粗的星号当成斜体去掉。
        check("**⟦重要⟧**", "***⟦重要⟧***") { MarkdownEditing.wrap("*", in: $0, selection: $1) }
    }

    func testLink() {
        check("看⟦文档⟧", "看[文档](|)") { MarkdownEditing.link(in: $0, selection: $1) }
        check("⟦https://example.com⟧", "[|](https://example.com)") { MarkdownEditing.link(in: $0, selection: $1) }
        check("|", "[|]()") { MarkdownEditing.link(in: $0, selection: $1) }
    }

    func testIndent() {
        check("- 一|", "  - 一|") { MarkdownEditing.indent(in: $0, selection: $1) }
        check("⟦  - 一\n    - 二⟧", "⟦- 一\n  - 二⟧") { MarkdownEditing.indent(in: $0, selection: $1, outdent: true) }
    }

    func testNewlineContinuesAndEndsLists() {
        func newline(_ marked: String) -> String? {
            let (text, selection) = parse(marked)
            return MarkdownEditing.newline(in: text, at: selection.location).map { render($0, on: text) }
        }
        XCTAssertEqual(newline("- 买菜|"), "- 买菜\n- |")
        XCTAssertEqual(newline("  - [x] 已做|\n下一行"), "  - [x] 已做\n  - [ ] |\n下一行")
        XCTAssertEqual(newline("9. 第九|"), "9. 第九\n10. |")
        XCTAssertEqual(newline("> 引用|"), "> 引用\n> |")
        XCTAssertEqual(newline("- 一\n- |"), "- 一\n|")
        XCTAssertNil(newline("正文|"))
    }
}
