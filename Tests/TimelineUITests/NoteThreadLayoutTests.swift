import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class NoteThreadLayoutTests: XCTestCase {
    private func row(scale: Double, metadata: Bool, actionWidth: CGFloat = 72,
                     width: CGFloat = 600, source: String = "A short journal note") -> NSHostingView<AnyView> {
        let log = DailyLogEntry(createdAt: Date(), kind: .note, text: source)
        let root = NoteThreadRow(log: log, actionWidth: actionWidth, showsMetadata: metadata) {
            Text("Associated task")
        } content: {
            TaskLinkText(source: log.text, completed: false, color: Palette.ink, fontSize: 13,
                         edit: {}, open: { _ in }, maxLines: 0, markdown: true, compactLines: true)
        } actions: {
            Image(systemName: "trash").frame(width: 24, height: 22)
        }
        let host = NSHostingView(rootView: AnyView(root.environment(\.typography, AppTypography(scale: scale, lineSpacing: 0))
            .frame(width: width).fixedSize(horizontal: false, vertical: true)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 120)
        host.layoutSubtreeIfNeeded()
        return host
    }

    func testLongMarkdownFitsInsideTheTimelineGutterAtNarrowAndWideWidths() throws {
        func text(in view: NSView) -> InteractiveTaskText? {
            (view as? InteractiveTaskText) ?? view.subviews.lazy.compactMap { text(in: $0) }.first
        }
        let source = Array(repeating: "长日记正文 **强调** 和 [链接](https://example.com)，缩窄窗口时需要完整换行。", count: 50).joined(separator: "\n\n")
        for scale in [0.8, 1.1, 1.5] {
            var previousHeight: CGFloat = .infinity
            for width: CGFloat in [300, 600, 1000] {
                let host = row(scale: scale, metadata: false, width: width, source: source)
                let view = try XCTUnwrap(text(in: host))
                let frame = view.convert(view.bounds, to: host)
                XCTAssertEqual(frame.minX, 88, accuracy: 0.5)
                XCTAssertEqual(frame.maxX, width - 8 - 78, accuracy: 0.5)
                XCTAssertEqual(host.fittingSize.height, view.bounds.height + 10, accuracy: 0.5)
                XCTAssertLessThanOrEqual(view.bounds.height, previousHeight)
                XCTAssertGreaterThan(view.bounds.height, 100)
                XCTAssertGreaterThanOrEqual(view.linkRegions().count, 50)
                XCTAssertTrue(view.linkRegions().allSatisfy { $0.url.absoluteString == "https://example.com" })
                previousHeight = view.bounds.height
            }
        }
    }

    func testPlainNotesRemoveTheEmptyMetadataLineAtEveryTextScale() {
        for scale in [0.8, 1.1, 1.5] {
            let plain = row(scale: scale, metadata: false)
            let contextual = row(scale: scale, metadata: true)
            XCTAssertLessThan(plain.fittingSize.height, contextual.fittingSize.height - 10)
            XCTAssertLessThan(plain.fittingSize.height, 40 * scale + 12)
        }
    }

    func testSelectionDoesNotChangePlainNoteHeightOrTextWidth() throws {
        func texts(in view: NSView) -> [InteractiveTaskText] {
            ((view as? InteractiveTaskText).map { [$0] } ?? []) + view.subviews.flatMap { texts(in: $0) }
        }
        let selection = LogKeyboardSelection.shared
        defer { selection.select(nil) }
        for scale in [0.8, 1.1, 1.5] {
            let editable = row(scale: scale, metadata: false, actionWidth: 96)
            let editText = try XCTUnwrap(texts(in: editable).first)
            func rowID(in view: NSView) -> UUID? {
                (view as? LogRowSelectionView)?.id ?? view.subviews.lazy.compactMap { rowID(in: $0) }.first
            }
            let id = try XCTUnwrap(rowID(in: editable))
            let height = editable.fittingSize.height, textWidth = editText.bounds.width
            for selected in [id, nil, id] {
                selection.select(selected, reveal: false)
                editable.layoutSubtreeIfNeeded()
                XCTAssertEqual(editable.fittingSize.height, height, accuracy: 0.5)
                XCTAssertEqual(editText.bounds.width, textWidth, accuracy: 0.5)
            }
            XCTAssertGreaterThan(editText.convert(editText.bounds, to: editable).minX, 80)
        }
    }

    func testCompactMarkdownKeepsParagraphsAndLinkTargets() throws {
        let root = TaskLinkText(source: "A [link](https://example.com)\n\nSecond paragraph", completed: false,
                                color: Palette.ink, fontSize: 13, edit: {}, open: { _ in },
                                maxLines: 0, markdown: true, compactLines: true)
        let host = NSHostingView(rootView: root.frame(width: 500).fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
        host.layoutSubtreeIfNeeded()
        func text(in view: NSView) -> InteractiveTaskText? {
            (view as? InteractiveTaskText) ?? view.subviews.lazy.compactMap { text(in: $0) }.first
        }
        let view = try XCTUnwrap(text(in: host))
        XCTAssertEqual(view.string.split(whereSeparator: \.isNewline).map(String.init), ["A link", "Second paragraph"])
        XCTAssertEqual(view.linkRegions().first?.url.absoluteString, "https://example.com")
    }
}
