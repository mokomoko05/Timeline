import Foundation
import XCTest
@testable import TimelineCore

/// 代码块的语法高亮：注释、字符串优先（里面的关键字不再着色），按语言选规则。
final class CodeHighlightTests: XCTestCase {
    private func kinds(_ code: String, _ language: String?) -> [String: CodeHighlight.Kind] {
        let text = code as NSString
        var result: [String: CodeHighlight.Kind] = [:]
        for token in CodeHighlight.tokens(code, language: language) { result[text.substring(with: token.range)] = token.kind }
        return result
    }

    func testPythonKeywordsStringsCommentsAndCalls() {
        let found = kinds("def fib(n):\n    # if in comment\n    return print(\"if in string\", 42)", "python")
        XCTAssertEqual(found["def"], .keyword)
        XCTAssertEqual(found["return"], .keyword)
        XCTAssertEqual(found["# if in comment"], .comment)
        XCTAssertEqual(found["\"if in string\""], .string)
        XCTAssertEqual(found["42"], .number)
        XCTAssertEqual(found["fib"], .function)
        XCTAssertNil(found["if"], "注释和字符串里的 if 不是关键字")
    }

    func testCLikeAndShellAndPlain() {
        let swift = kinds("// note\nlet value = Foo(\"a // b\") /* block */", "swift")
        XCTAssertEqual(swift["// note"], .comment)
        XCTAssertEqual(swift["\"a // b\""], .string)
        XCTAssertEqual(swift["/* block */"], .comment)
        XCTAssertEqual(swift["let"], .keyword)
        XCTAssertEqual(swift["Foo"], .function)
        let shell = kinds("echo $HOME --flag # done", "bash")
        XCTAssertEqual(shell["echo"], .keyword)
        XCTAssertEqual(shell["$HOME"], .attribute)
        XCTAssertEqual(shell["# done"], .comment)
        XCTAssertTrue(CodeHighlight.tokens("if x", language: "text").isEmpty)
    }
}
