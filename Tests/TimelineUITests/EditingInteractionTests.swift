import AppKit
import XCTest
@testable import Timeline

final class EditingInteractionTests: XCTestCase {
    @MainActor
    func testPDFAndWebLinksChooseSafari() async {
        XCTAssertTrue(SafariLinks.usesSafari(URL(fileURLWithPath: "/Users/example/Reading/eurosys27-extra-paper1384.pdf")))
        XCTAssertTrue(SafariLinks.usesSafari(URL(fileURLWithPath: "/tmp/论文.PDF")))
        XCTAssertTrue(SafariLinks.usesSafari(URL(string: "https://example.com")!))
        XCTAssertFalse(SafariLinks.usesSafari(URL(fileURLWithPath: "/tmp/notes.txt")))
    }

    @MainActor
    func testMarkedTextDoesNotSubmitCancelOrRecallHistory() async {
        var submitted = false
        var cancelled = false
        var recalled = false
        let input = GrowingTaskInput(text: .constant(""), focused: .constant(true),
                                     submit: { submitted = true }, cancel: { cancelled = true },
                                     historyUp: { recalled = true }, minHeight: 24)
        let coordinator = input.makeCoordinator()
        let editor = ImagePasteTextView()
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.moveUp(_:))] {
            XCTAssertFalse(coordinator.textView(editor, doCommandBy: selector))
        }
        XCTAssertFalse(submitted)
        XCTAssertFalse(cancelled)
        XCTAssertFalse(recalled)
        editor.unmarkText()
        XCTAssertFalse(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))), "组词结束后，普通 Enter 换行，不提交")
        XCTAssertFalse(submitted)
    }

    @MainActor
    func testEurosysNativeLinkOpensWithoutEnteringEditing() async throws {
        let address = "file:///Users/example/Reading/eurosys27-extra-paper1384.pdf"
        let text = TaskLinkText.styledText("[eurosys](\(address))", completed: false, color: .labelColor, fontSize: 13)
        let view = InteractiveTaskText(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        view.isEditable = false
        view.textStorage?.setAttributedString(text)
        let container = try XCTUnwrap(view.textContainer)
        let manager = try XCTUnwrap(view.layoutManager)
        manager.ensureLayout(for: container)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: 0, length: text.length), in: container)
        var opened: URL?
        view.onOpen = { opened = $0 }
        view.activate(at: NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y))
        XCTAssertEqual(opened, URL(string: address))
        XCTAssertFalse(view.isEditable)
    }
}
