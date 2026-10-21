import AppKit
import SwiftUI
import XCTest
@testable import Timeline

@MainActor
final class BoardMarkdownEditorTests: XCTestCase {
    private func fixture(source: String) throws -> EditorFixture {
        let state = EditorState(source: source)
        let host = NSHostingView(rootView: EditorHarness(state: state))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 260),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func editors(_ view: NSView) -> [BoardMarkdownTextView] {
            (view as? BoardMarkdownTextView).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        let editor = try XCTUnwrap(editors(host).first)
        window.makeFirstResponder(editor)
        return EditorFixture(state: state, host: host, window: window, editor: editor)
    }

    func testMiddleTypingBatchesUpdatesAndKeepsCaretAndScrollAcrossRefreshes() async throws {
        let source = (0..<1_500).map { "Line \($0): 中文与 Markdown **content**" }.joined(separator: "\n")
        let fixture = try fixture(source: source)
        defer { fixture.close() }
        let editor = fixture.editor
        let start = (source as NSString).range(of: "Line 700:").location + 10
        editor.setSelectedRange(NSRange(location: start, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        let insertion = "输入abc🙂"
        for _ in 0..<30 { editor.insertText(insertion, replacementRange: editor.selectedRange()) }
        let expectedSelection = NSRange(location: start + (insertion as NSString).length * 30, length: 0)
        let expectedText = editor.string
        let origin = editor.enclosingScrollView?.contentView.bounds.origin
        XCTAssertEqual(fixture.state.updates, 0)
        XCTAssertEqual(editor.selectedRange(), expectedSelection)
        fixture.state.revision += 1
        try await Task.sleep(for: .milliseconds(60))
        fixture.host.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.string, expectedText)
        XCTAssertEqual(editor.selectedRange(), expectedSelection)
        try await Task.sleep(for: .milliseconds(200))
        fixture.host.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.state.updates, 1)
        XCTAssertEqual(fixture.state.source, expectedText)
        XCTAssertEqual(editor.selectedRange(), expectedSelection)
        XCTAssertEqual(editor.enclosingScrollView?.contentView.bounds.origin, origin)
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        XCTAssertNotEqual(editor.string, expectedText)
        fixture.window.makeFirstResponder(nil)
        XCTAssertEqual(fixture.state.source, editor.string)
    }

    func testChineseCompositionSurvivesRefreshAndOnlyCommitsCompletedText() async throws {
        let fixture = try fixture(source: "Before\n\n正文\n\nAfter")
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(60))
        let editor = fixture.editor
        let start = (editor.string as NSString).range(of: "正文").location
        editor.setSelectedRange(NSRange(location: start, length: 0))
        editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let selection = editor.selectedRange()
        let marked = editor.markedRange()
        fixture.state.revision += 1
        try await Task.sleep(for: .milliseconds(240))
        fixture.host.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(fixture.state.updates, 0)
        editor.insertText("中文", replacementRange: marked)
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(fixture.state.source, "Before\n\n中文正文\n\nAfter")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: start + 2, length: 0))
        XCTAssertEqual(fixture.state.updates, 1)
    }

    func testExternalEditsPreserveSelectionAndCancelStalePendingInput() async throws {
        let fixture = try fixture(source: "Before\n\nBody\n\nAfter")
        defer { fixture.close() }
        let editor = fixture.editor
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        editor.insertText("local", replacementRange: editor.selectedRange())
        let selection = editor.selectedRange()
        fixture.state.source = "Updated externally with more content"
        try await Task.sleep(for: .milliseconds(260))
        fixture.host.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.string, fixture.state.source)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(fixture.state.updates, 0)
        fixture.state.source = "短"
        try await Task.sleep(for: .milliseconds(60))
        fixture.host.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.string, "短")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 0))
    }

    func testBlurAndApplicationCommitFlushImmediatelyAndTemplatesKeepNativeUndo() throws {
        let fixture = try fixture(source: "Before\n\nBody\n\nAfter")
        defer { fixture.close() }
        let editor = fixture.editor
        editor.setSelectedRange((editor.string as NSString).range(of: "Body"))
        editor.insertText("New body", replacementRange: editor.selectedRange())
        XCTAssertEqual(fixture.state.updates, 0)
        fixture.window.makeFirstResponder(nil)
        XCTAssertEqual(fixture.state.source, "Before\n\nNew body\n\nAfter")
        fixture.window.makeFirstResponder(editor)
        editor.setSelectedRange((editor.string as NSString).range(of: "New body"))
        XCTAssertTrue(BoardMarkdownTemplate.disclosure.insert(into: editor))
        let source = editor.string
        let selection = editor.selectedRange()
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        XCTAssertEqual(fixture.state.source, source)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        XCTAssertEqual(fixture.state.source, editor.string)
        XCTAssertNotEqual(editor.string, source)
    }

    func testCommandReturnFlushesBeforePreviewAndDoesNotInterruptComposition() async throws {
        let fixture = try fixture(source: "Before\n\nAfter")
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(60))
        let editor = fixture.editor
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        editor.insertText("中间文字", replacementRange: editor.selectedRange())
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                  timestamp: 0, windowNumber: fixture.window.windowNumber,
                                                  context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                  isARepeat: false, keyCode: 36))
        editor.keyDown(with: event)
        XCTAssertEqual(fixture.state.source, "Before\n\n中间文字After")
        XCTAssertEqual(fixture.state.previews, 1)
        editor.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(editor.shouldInterceptReturn(event))
        fixture.window.makeFirstResponder(nil)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(fixture.state.source, editor.string)
    }
}

@MainActor
private final class EditorState: ObservableObject {
    @Published var source: String
    @Published var revision = 0
    var updates = 0
    var previews = 0

    init(source: String) { self.source = source }

    func update(_ source: String) {
        updates += 1
        self.source = source
    }
}

private struct EditorHarness: View {
    @ObservedObject var state: EditorState

    var body: some View {
        BoardMarkdownEditor(text: Binding(get: { state.source }, set: state.update), preview: { state.previews += 1 })
            .opacity(state.revision.isMultiple(of: 2) ? 1 : 0.99)
    }
}

@MainActor
private struct EditorFixture {
    let state: EditorState
    let host: NSHostingView<EditorHarness>
    let window: NSWindow
    let editor: BoardMarkdownTextView

    func close() {
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
    }
}
