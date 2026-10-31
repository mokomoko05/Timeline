import XCTest
@testable import TimelineCore

final class TaskTextTests: XCTestCase {
    func testDeletedTaskTitleKeepsBareURLClickable() {
        let flattened = String(TaskText.rendered("看 https://example.com/a 这篇").characters)
        XCTAssertEqual(TaskText.rendered(flattened).runs.compactMap(\.link), [URL(string: "https://example.com/a")!])
    }

    func testMarkdownAliasRendersAsClickableName() {
        let rendered = TaskText.rendered("阅读 [论文](https://arxiv.org/abs/1234.5678)")
        XCTAssertEqual(String(rendered.characters), "阅读 论文")
        XCTAssertEqual(rendered.runs.compactMap(\.link).map(\.absoluteString), ["https://arxiv.org/abs/1234.5678"])
    }

    func testBareURLsAreLinkedAlongsideUnicodeAndMarkdownLinks() {
        let rendered = TaskText.rendered("✅ 中文 [资料](https://example.com/docs) 和 https://github.com/openai")
        let links = Set(rendered.runs.compactMap(\.link).map(\.absoluteString))
        XCTAssertEqual(links, ["https://example.com/docs", "https://github.com/openai"])
        XCTAssertEqual(String(rendered.characters), "✅ 中文 资料 和 https://github.com/openai")
    }

    func testExplicitLinkTargetIsNotReplacedByURLInItsLabel() {
        let rendered = TaskText.rendered("[example.com](https://github.com)")
        XCTAssertEqual(rendered.runs.compactMap(\.link).map(\.absoluteString), ["https://github.com"])
    }

    func testMarkdownAliasCanUseDomainWithoutScheme() {
        let rendered = TaskText.rendered("[资料](example.com/docs)")
        XCTAssertEqual(rendered.runs.compactMap(\.link).map(\.absoluteString), ["https://example.com/docs"])
    }

    func testLocalFilesAreInteractiveButUnsupportedSchemesAreNot() {
        let rendered = TaskText.rendered("[本地](file:///tmp/test) [脚本](javascript:alert) [邮件](mailto:user@example.com)")
        XCTAssertEqual(rendered.runs.compactMap(\.link), [URL(string: "file:///tmp/test")!])
        XCTAssertNil(TaskText.webURL("file:///tmp/test"))
        XCTAssertNil(TaskText.webURL("javascript:alert(1)"))
        XCTAssertNil(TaskText.webURL("https://"))
        XCTAssertNil(TaskText.webURL("不是网址"))
    }

    func testEurosysFileAliasAndPathsWithSpaces() throws {
        let address = "file:///Users/example/Reading/eurosys27-extra-paper1384.pdf"
        let rendered = TaskText.rendered("[eurosys](\(address))")
        XCTAssertEqual(String(rendered.characters), "eurosys")
        XCTAssertEqual(rendered.runs.compactMap(\.link), [URL(string: address)!])
        let spaced = try XCTUnwrap(TaskText.linkURL("/tmp/论文 review.pdf"))
        XCTAssertTrue(spaced.isFileURL)
        let roundTrip = TaskText.rendered(TaskText.markdownLink(label: "paper", url: spaced))
        XCTAssertEqual(roundTrip.runs.compactMap(\.link), [spaced])
        XCTAssertNil(TaskText.linkURL("file://remote-server/tmp/test"))
    }

    func testLinkComposerEscapesAliasAndKeepsURLParentheses() throws {
        let url = try XCTUnwrap(TaskText.webURL("https://example.com/paper(v2)"))
        let markdown = TaskText.markdownLink(label: "论文 [第二版]", url: url)
        let rendered = TaskText.rendered(markdown)
        XCTAssertEqual(String(rendered.characters), "论文 [第二版]")
        XCTAssertEqual(rendered.runs.compactMap(\.link), [url])
    }

    func testWebAddressNormalizationAndEmptyAlias() throws {
        let url = try XCTUnwrap(TaskText.webURL(" github.com/openai "))
        XCTAssertEqual(url.absoluteString, "https://github.com/openai")
        XCTAssertEqual(String(TaskText.rendered(TaskText.markdownLink(label: "", url: url)).characters), "github.com")
    }

    func testIncompleteMarkdownRemainsReadable() {
        let rendered = TaskText.rendered("写到一半 [资料](")
        XCTAssertEqual(String(rendered.characters), "写到一半 [资料](")
    }

    func testCalendarAliasIsLiteralAndKeepsSingleFileLink() {
        let address = "file:///Users/example/Reading/eurosys27-extra-paper1384.pdf"
        let source = "阅读全文 [eurosys](\(address)) 并整理笔记"
        let rendered = TaskText.rendered(source, alias: "[EuroSys] *阅读*")
        XCTAssertEqual(String(rendered.characters), "[EuroSys] *阅读*")
        XCTAssertEqual(rendered.runs.compactMap(\.link), [URL(string: address)!])
        XCTAssertEqual(TaskText.rendered(source, alias: " \n "), TaskText.rendered(source))
    }

    func testCalendarAliasDoesNotPickAnArbitraryLinkFromMultipleDestinations() {
        let source = "[一](https://example.com/one) [二](https://example.com/two)"
        let rendered = TaskText.rendered(source, alias: "资料")
        XCTAssertEqual(String(rendered.characters), "资料")
        XCTAssertTrue(rendered.runs.compactMap(\.link).isEmpty)
        XCTAssertTrue(TaskText.rendered("普通任务", alias: "https://example.com").runs.compactMap(\.link).isEmpty)
    }
}
