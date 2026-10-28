import AppKit
import Combine
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class JournalScrollRegressionTests: XCTestCase {
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    func testScrollNotificationsPublishOnceAfterTheLayoutTransaction() async throws {
        let tracker = ScrollTracker()
        let ids = (0..<40).map { _ in UUID() }
        let root = ScrollView {
            VStack(spacing: 0) {
                ForEach(ids, id: \.self) { id in
                    Color.clear.frame(height: 50).recordsScrollPosition(id, in: tracker)
                }
            }.tracksScroll(tracker)
        }.frame(width: 300, height: 300)
        let host = NSHostingView(rootView: root)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        let scroll = try XCTUnwrap(scrollViews(in: host).first)
        var publications = 0
        let subscription = tracker.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        for offset in [400.0, 450.0, 505.0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        XCTAssertEqual(publications, 0)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(tracker.current, ids[10])
    }

    func testHoverActionsKeepHeaderHeightStableAtEveryTextScale() {
        for scale in [0.8, 1.1, 1.5] {
            func height(showsActions: Bool) -> CGFloat {
                let header = NoteThreadHeader(showsActions: showsActions, actionWidth: 96) {
                    Text("12:34").fixedSize()
                    Text("Source with several tags and a title that wraps across multiple lines")
                        .fixedSize(horizontal: false, vertical: true)
                } actions: {
                    HStack(spacing: 0) {
                        ForEach(["doc.on.doc", "tag", "link", "trash"], id: \.self) { symbol in
                            Image(systemName: symbol).frame(width: 24, height: 22)
                        }
                    }
                }
                let host = NSHostingView(rootView: header.font(.system(size: 11 * scale)).frame(width: 360)
                    .fixedSize(horizontal: false, vertical: true))
                host.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
                host.layoutSubtreeIfNeeded()
                return host.fittingSize.height
            }
            XCTAssertEqual(height(showsActions: false), height(showsActions: true), accuracy: 0.5)
        }
    }

    func testScrollingCancelsPendingHoverPreparation() async throws {
        let editor = InlineMarkdownEditor()
        editor.preparesInTests = true
        var prepared = false
        editor.prepareSoon(UUID()) { prepared = true }
        editor.didScroll(in: NSScrollView())
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(prepared)
    }

    func testScrollingReleasesPreparedEditorAndPreservesActiveEditing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let date = Date()
        let log = try XCTUnwrap(store.quickLogEntry("A note\n\nMore text", linkDefault: false, on: date).entry)
        let editor = InlineMarkdownEditor.shared
        editor.finish()
        let root = ScrollView {
            VStack {
                EditableLogText(log: log, editable: true, begin: { point, prepare in
                    editor.begin(log, on: date, store: store, at: point, fontSize: 13, lineSpacing: 2, dark: false, prepare: prepare)
                }) { _ in
                    Text(log.text).frame(maxWidth: .infinity, alignment: .leading)
                }
                Color.clear.frame(height: 1000)
            }
        }.frame(width: 420, height: 300)
        let host = NSHostingView(rootView: root)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { editor.finish(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(scrollViews(in: host).first)
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false, prepare: true)
        for _ in 0..<100 where editor.webView?.enclosingScrollView !== scroll {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertTrue(editor.webView?.enclosingScrollView === scroll)
        editor.didScroll(in: scroll)
        XCTAssertNil(editor.target)
        XCTAssertEqual(store.entry(for: date).logs.first?.text, log.text)
        editor.begin(log, on: date, store: store, at: nil, fontSize: 13, lineSpacing: 2, dark: false)
        editor.didScroll(in: scroll)
        XCTAssertTrue(editor.isEditing(log.id))
    }
}
