import XCTest
@testable import TimelineCore

final class MarkdownDisclosuresTests: XCTestCase {
    func testSpansMatchKeysAndSkipCode() {
        let source = "<details open>\n<summary>甲 &amp; 乙</summary>\n\n内容\n</details>\n\n```\n<details>\n</details>\n```\n\n<details>\n\n正文\n\n</details>\n\n<details><summary>甲 & 乙</summary>\n</details>"
        let spans = MarkdownDisclosures.spans(source.components(separatedBy: "\n"), untitled: "Collapsible")
        XCTAssertEqual(spans.map(\.key), ["d:甲 & 乙#0", "d:折叠内容#0", "d:甲 & 乙#1"], "键不随界面语言变")
        XCTAssertEqual(spans.map(\.initiallyOpen), [true, false, false])
        XCTAssertEqual(spans.map(\.title), ["甲 & 乙", "Collapsible", "甲 & 乙"])
        XCTAssertEqual(spans[0].bodyStart, 3)
        XCTAssertEqual(spans[0].closing, 5)
    }

    func testUnclosedDisclosureIsNotASpan() {
        XCTAssertTrue(MarkdownDisclosures.spans(["<details>", "内容"]).isEmpty)
    }

    func testFoldRecordsRememberClosedOpenDisclosure() {
        var records: Set<String> = []
        XCTAssertTrue(FoldRecords.isOpen("d:甲#0", initially: true, in: records))
        XCTAssertFalse(FoldRecords.isOpen("d:甲#0", initially: false, in: records))

        FoldRecords.set("d:甲#0", value: false, in: &records)
        XCTAssertEqual(records, ["d:甲#0=closed"])
        XCTAssertFalse(FoldRecords.isOpen("d:甲#0", initially: true, in: records), "<details open> 收起后要记得住")

        FoldRecords.set("d:甲#0", value: true, in: &records)
        XCTAssertEqual(records, ["d:甲#0=open"])
        XCTAssertTrue(FoldRecords.isOpen("d:甲#0", initially: false, in: records))
    }

    func testFoldRecordsLegacyAndHeadings() {
        var records: Set<String> = ["d:旧#0"]
        XCTAssertTrue(FoldRecords.isOpen("d:旧#0", initially: false, in: records), "编辑器旧版存的没有后缀，表示展开")
        FoldRecords.set("d:旧#0", value: false, in: &records)
        XCTAssertEqual(records, ["d:旧#0=closed"])

        FoldRecords.set("h1:标题#0", value: true, in: &records)
        XCTAssertEqual(FoldRecords.editorFolds(records), ["d:旧#0": false, "h1:标题#0": true])
        FoldRecords.set("h1:标题#0", value: false, in: &records)
        XCTAssertEqual(records, ["d:旧#0=closed"])
    }

    func testDisclosureTargetSplitsToggleRecords() {
        XCTAssertEqual(FoldRecords.disclosureTarget("d:甲#0=closed")?.name, "d:甲#0")
        XCTAssertEqual(FoldRecords.disclosureTarget("d:甲#0=closed")?.open, false)
        XCTAssertNil(FoldRecords.disclosureTarget("h1:标题#0"))
    }
}
