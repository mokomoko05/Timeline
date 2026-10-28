import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class NoteThreadLayoutTests: XCTestCase {
    private func row(scale: Double, metadata: Bool, actionWidth: CGFloat = 72) -> NSHostingView<AnyView> {
        let log = DailyLogEntry(createdAt: Date(), kind: .note, text: "A short journal note")
        let root = NoteThreadRow(log: log, actionWidth: actionWidth, showsMetadata: metadata) {
            Text("Associated task")
        } content: {
            TaskLinkText(source: log.text, completed: false, color: Palette.ink, fontSize: 13,
                         edit: {}, open: { _ in }, maxLines: 0, markdown: true, compactLines: true)
        } actions: {
            Image(systemName: "trash").frame(width: 24, height: 22)
        }
        let host = NSHostingView(rootView: AnyView(root.environment(\.typography, AppTypography(scale: scale, lineSpacing: 0))
            .frame(width: 600).fixedSize(horizontal: false, vertical: true)))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 120)
        host.layoutSubtreeIfNeeded()
        return host
    }

    func testPlainNotesRemoveTheEmptyMetadataLineAtEveryTextScale() {
        for scale in [0.8, 1.1, 1.5] {
            let plain = row(scale: scale, metadata: false)
            let contextual = row(scale: scale, metadata: true)
            XCTAssertLessThan(plain.fittingSize.height, contextual.fittingSize.height - 10)
            XCTAssertLessThan(plain.fittingSize.height, 40 * scale + 12)
        }
    }

    func testHoverActionReservationKeepsPlainNoteHeightAndTextWidthStable() throws {
        func texts(in view: NSView) -> [InteractiveTaskText] {
            ((view as? InteractiveTaskText).map { [$0] } ?? []) + view.subviews.flatMap { texts(in: $0) }
        }
        for scale in [0.8, 1.1, 1.5] {
            let readOnly = row(scale: scale, metadata: false, actionWidth: 0)
            let editable = row(scale: scale, metadata: false, actionWidth: 96)
            XCTAssertEqual(readOnly.fittingSize.height, editable.fittingSize.height, accuracy: 0.5)
            let readText = try XCTUnwrap(texts(in: readOnly).first)
            let editText = try XCTUnwrap(texts(in: editable).first)
            XCTAssertEqual(readText.bounds.width, editText.bounds.width, accuracy: 0.5)
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
