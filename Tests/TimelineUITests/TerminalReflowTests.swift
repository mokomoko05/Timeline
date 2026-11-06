import XCTest
import SwiftTerm

private final class SilentTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// 终端变窄时的重排：纯 Terminal，不建窗口。
final class TerminalReflowTests: XCTestCase {
    /// 宽字符被截断后留在最后一列，原先会让下一次变窄的重排越界写堆（开久了随机崩溃）。
    func testWideCharacterCutAtLastColumnDoesNotOverrunReflow() {
        let terminal = Terminal(delegate: SilentTerminalDelegate(), options: TerminalOptions(cols: 11, rows: 5, scrollback: 100))
        terminal.feed(text: "a中中中中中")   // 最后一个「中」占第 9–10 列，光标留在这一行
        terminal.resize(cols: 10, rows: 5)   // 光标行不重排，只截断：「中」的左半格留在最后一列
        let line = try! XCTUnwrap(terminal.getLine(row: 0))
        XCTAssertLessThanOrEqual(line.getTrimmedLength(), line.count)

        terminal.feed(text: "\r\nnext\r\n")
        terminal.resize(cols: 4, rows: 5)    // 这一行离开光标后参与重排
        terminal.resize(cols: 30, rows: 5)
        let text = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
        // 宽字符的后半格导出成 NUL，比较前去掉。
        XCTAssertTrue(text.replacingOccurrences(of: "\0", with: "").contains("a中中中中"), text)
        XCTAssertTrue(text.contains("next"), text)
    }

    /// 大量中文输出加反复改尺寸（分栏、拖窗口）：每次改尺寸后每行的有效长度都不超过行长。
    func testRepeatedResizesWithWideOutputKeepLineLengthsInBounds() {
        let terminal = Terminal(delegate: SilentTerminalDelegate(), options: TerminalOptions(cols: 120, rows: 40, scrollback: 2_000))
        var generator = SystemRandomNumberGenerator()
        let pieces = ["你好", "世界", "终端", "🙂", "abc", "x", "한글", " "]
        for round in 0..<300 {
            var output = ""
            for _ in 0..<Int.random(in: 1...20, using: &generator) {
                output += pieces.randomElement(using: &generator)!
                if Int.random(in: 0..<6, using: &generator) == 0 { output += "\r\n" }
            }
            terminal.feed(text: output)
            if round % 3 == 0 {
                terminal.resize(cols: Int.random(in: 40...200, using: &generator), rows: Int.random(in: 10...60, using: &generator))
                for row in 0..<terminal.rows {
                    guard let line = terminal.getLine(row: row) else { continue }
                    XCTAssertLessThanOrEqual(line.getTrimmedLength(), line.count)
                }
            }
        }
    }
}
