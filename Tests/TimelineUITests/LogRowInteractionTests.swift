import AppKit
import Combine
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class LogRowInteractionTests: XCTestCase {
    private struct ActionProbe: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.identifier = NSUserInterfaceItemIdentifier("log-actions-probe")
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, of: type) }
    }

    private func event(_ type: NSEvent.EventType = .leftMouseDown, in view: NSView, at point: NSPoint, clickCount: Int = 1) throws -> NSEvent {
        let window = try XCTUnwrap(view.window)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0))
    }

    private func makeHost(_ log: DailyLogEntry, width: CGFloat = 600, scale: Double = 1.1, actionWidth: CGFloat = 72,
                          prepare: (() -> Void)? = nil,
                          edit: @escaping (CGPoint?) -> Void = { _ in }) -> NSHostingView<AnyView> {
        let row = NoteThreadRow(log: log, actionWidth: actionWidth, showsMetadata: false, prepareEdit: prepare) {} content: {
            EditableLogText(log: log, editable: true, begin: { point, _ in edit(point) }) { editAt in
                TaskLinkText(source: log.text, completed: false, color: Palette.ink, fontSize: 13,
                             edit: { edit(nil) }, open: { _ in }, maxLines: 0, markdown: true, compactLines: true,
                             editAt: editAt, foldID: "row-interaction.\(log.id)")
            }
        } actions: { ActionProbe().frame(width: actionWidth, height: 22) }
        return NSHostingView(rootView: AnyView(row.environment(\.typography, AppTypography(scale: scale, lineSpacing: 0))
            .frame(width: width).fixedSize(horizontal: false, vertical: true)))
    }

    private func makeWindow(_ host: NSView, width: CGFloat = 600) -> QuietWindow {
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func actions(in host: NSView) -> [NSView] {
        descendants(host, of: NSView.self).filter { $0.identifier?.rawValue == "log-actions-probe" && !$0.isHiddenOrHasHiddenAncestor }
    }

    func testFirstClickSelectsAndPreparesWithoutScrollingOrEditingAndNextClickEdits() async throws {
        try await preparedClick(clickCount: 1)
    }

    func testDoubleClickAfterSelectionHandsOriginalEventToPreparedEditor() async throws {
        try await preparedClick(clickCount: 2)
    }

    private func preparedClick(clickCount: Int) async throws {
        let selection = LogKeyboardSelection.shared
        let editor = InlineMarkdownEditor.shared
        selection.select(nil)
        editor.finish()
        let previousPreparation = editor.preparesInTests
        editor.preparesInTests = true
        defer { editor.preparesInTests = previousPreparation }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory), date = Date()
        let log = try XCTUnwrap(store.quickLogEntry("First select, then edit this note.", linkDefault: false, on: date).entry)
        var editCalls = 0
        let host = makeHost(log, prepare: {
            editor.begin(log, on: date, store: store, at: nil, fontSize: 14.3, lineSpacing: 0, dark: false, prepare: true)
        }) { point in
            editCalls += 1
            editor.begin(log, on: date, store: store, at: point, fontSize: 14.3, lineSpacing: 0, dark: false)
        }
        let window = makeWindow(host)
        defer { editor.finish(); selection.select(nil); window.contentView = nil; window.close() }
        // 透明测试窗口会让 WebKit 停跑动画帧；沿用对齐测试的办法测量正常绘制路径，窗口仍保持透明。
        let webView = editor.makeWebView()
        let occlusionSelector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        func occlusionDetection(_ enabled: Bool) {
            guard webView.responds(to: occlusionSelector) else { return }
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: occlusionSelector), to: Setter.self)(webView, occlusionSelector, enabled)
        }
        occlusionDetection(false)
        defer { occlusionDetection(true) }
        let text = try XCTUnwrap(descendants(host, of: InteractiveTaskText.self).first)
        let point = NSPoint(x: 30, y: 8)
        var scrolls = 0
        let subscription = selection.scrollRequests.sink { _ in scrolls += 1 }
        defer { subscription.cancel() }
        XCTAssertTrue(actions(in: host).isEmpty)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(selection.handleMouseDown(try event(in: text, at: point)))
        host.layoutSubtreeIfNeeded()
        print(String(format: "LOG SELECTION click-to-layout %.2fms", (ProcessInfo.processInfo.systemUptime - started) * 1000))
        XCTAssertEqual(selection.selectedID, log.id)
        XCTAssertEqual(scrolls, 0, "Mouse selection must preserve the current scroll position")
        XCTAssertFalse(actions(in: host).isEmpty)
        XCTAssertNil(editor.target, "Selection must paint before preparation begins")
        for _ in 0..<500 where editor.height == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(editor.target?.logID, log.id)
        XCTAssertTrue(editor.preparing)
        XCTAssertFalse(editor.isEditing(log.id))
        XCTAssertFalse(editor.hasTextFocus)
        XCTAssertEqual(text.alphaValue, 1, "Prepared editing must leave the rendered text visible")

        selection.select(nil)
        XCTAssertNil(editor.target, "Deselecting must discard the prepared editor")
        XCTAssertEqual(store.entry(for: date).logs.first?.text, log.text)
        XCTAssertNil(selection.handleMouseDown(try event(in: text, at: point)))
        for _ in 0..<500 where editor.height == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(editor.height)

        let second = try event(in: text, at: point, clickCount: clickCount)
        XCTAssertNotNil(selection.handleMouseDown(second))
        NSApp.postEvent(try event(.leftMouseUp, in: text, at: point), atStart: true)
        let editStarted = ProcessInfo.processInfo.systemUptime
        text.mouseDown(with: second)
        XCTAssertTrue(editor.isEditing(log.id))
        XCTAssertEqual(editCalls, 0, "The original click, including its click count, must go to the prepared WebKit editor")
        for _ in 0..<500 where editor.height == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(editor.height)
        print(String(format: "LOG EDIT second-click-to-ready %.2fms", (ProcessInfo.processInfo.systemUptime - editStarted) * 1000))
    }

    func testFastDoubleClickBeforePreparationEditsAtClickedPosition() throws {
        let selection = LogKeyboardSelection.shared
        let editor = InlineMarkdownEditor.shared
        editor.finish()
        selection.select(nil)
        let log = DailyLogEntry(createdAt: Date(), kind: .note, text: "First select, then double click here.")
        var edits: [CGPoint?] = []
        let host = makeHost(log) { edits.append($0) }
        let window = makeWindow(host)
        defer { selection.select(nil); window.contentView = nil; window.close() }
        let text = try XCTUnwrap(descendants(host, of: InteractiveTaskText.self).first)
        let point = NSPoint(x: 30, y: 8)
        XCTAssertNil(selection.handleMouseDown(try event(in: text, at: point)))
        XCTAssertEqual(selection.selectedID, log.id)
        XCTAssertTrue(edits.isEmpty)
        XCTAssertNil(editor.target)
        let second = try event(in: text, at: point, clickCount: 2)
        XCTAssertNotNil(selection.handleMouseDown(second))
        text.mouseDown(with: second)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(try XCTUnwrap(edits.first.flatMap { $0 }), NSPoint(x: point.x - text.textContainerOrigin.x, y: point.y - text.textContainerOrigin.y))
    }

    func testSelectedActionsLeaveHeadingAndItsHitAreaUnobstructedAtEveryScale() throws {
        let selection = LogKeyboardSelection.shared
        defer { selection.select(nil) }
        for scale in [0.8, 1.1, 1.5] {
            for width: CGFloat in [300, 600] {
                for actionWidth: CGFloat in [72, 96] {
                    let log = DailyLogEntry(createdAt: Date(), kind: .note, text: "# A long title that may wrap\n\nContent under this heading.")
                    let host = makeHost(log, width: width, scale: scale, actionWidth: actionWidth)
                    let window = makeWindow(host, width: width)
                    defer { window.contentView = nil; window.close() }
                    selection.select(log.id, reveal: false)
                    host.layoutSubtreeIfNeeded()
                    let text = try XCTUnwrap(descendants(host, of: InteractiveTaskText.self).first)
                    let heading = try XCTUnwrap(text.headingRegions().first)
                    let action = try XCTUnwrap(actions(in: host).first)
                    let actionRect = action.convert(action.bounds, to: host)
                    let headingHitRect = text.convert(heading.rect.insetBy(dx: -4, dy: -4), to: host)
                    XCTAssertFalse(actionRect.intersects(headingHitRect), "Delete and fold hit areas must remain separate")
                    XCTAssertLessThan(headingHitRect.maxX, actionRect.minX)
                }
            }
        }
    }

    func testFoldingAndLinksStillPassThroughOnTheFirstClickAndBlankAreaDeselects() throws {
        let selection = LogKeyboardSelection.shared
        selection.select(nil)
        let log = DailyLogEntry(createdAt: Date(), kind: .note, text: "# Title\n\nA [link](https://example.com).")
        let host = makeHost(log)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        host.frame = NSRect(x: 0, y: 100, width: 600, height: host.fittingSize.height)
        container.addSubview(host)
        let window = makeWindow(container)
        defer { selection.select(nil); window.contentView = nil; window.close() }
        let text = try XCTUnwrap(descendants(host, of: InteractiveTaskText.self).first)
        let fold = try XCTUnwrap(text.headingRegions().first)
        XCTAssertNotNil(selection.handleMouseDown(try event(in: text, at: NSPoint(x: fold.rect.midX, y: fold.rect.midY))))
        XCTAssertEqual(selection.selectedID, log.id)
        selection.select(nil, reveal: false)
        let link = try XCTUnwrap(text.linkRegions().first)
        XCTAssertNotNil(selection.handleMouseDown(try event(in: text, at: NSPoint(x: link.rect.midX, y: link.rect.midY))))
        XCTAssertEqual(selection.selectedID, log.id)
        let blank = NSPoint(x: 5, y: 5)
        let area = try XCTUnwrap(descendants(host, of: LogRowSelectionView.self).first)
        XCTAssertFalse(area.bounds.intersection(area.visibleRect).contains(area.convert(blank, from: container)),
                       "The test click must be outside the row")
        XCTAssertNotNil(selection.handleMouseDown(try event(in: container, at: blank)))
        XCTAssertNil(selection.selectedID)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(actions(in: host).isEmpty)
    }

    func testSwitchingRowsOnlyPreparesCurrentSelectionAndDeselectingCancels() async throws {
        let selection = LogKeyboardSelection.shared, editor = InlineMarkdownEditor.shared
        editor.finish()
        selection.select(nil)
        let previousPreparation = editor.preparesInTests
        editor.preparesInTests = true
        let logs = ["First row", "Second row"].map { DailyLogEntry(createdAt: Date(), kind: .note, text: $0) }
        var prepared: [UUID] = []
        let hosts = logs.map { log in makeHost(log, prepare: { prepared.append(log.id) }) }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        for (index, host) in hosts.enumerated() {
            host.frame = NSRect(x: 0, y: CGFloat(100 + index * 100), width: 600, height: host.fittingSize.height)
            container.addSubview(host)
        }
        let window = makeWindow(container)
        defer {
            selection.select(nil)
            editor.preparesInTests = previousPreparation
            window.contentView = nil
            window.close()
        }
        for (index, host) in hosts.enumerated() {
            let text = try XCTUnwrap(descendants(host, of: InteractiveTaskText.self).first)
            XCTAssertNil(selection.handleMouseDown(try event(in: text, at: NSPoint(x: 30, y: 8))))
            XCTAssertEqual(selection.selectedID, logs[index].id, "Each row must use its own bounds, even when visibleRect extends beyond them")
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(prepared, [logs[1].id])
        let first = try XCTUnwrap(descendants(hosts[0], of: InteractiveTaskText.self).first)
        XCTAssertNil(selection.handleMouseDown(try event(in: first, at: NSPoint(x: 30, y: 8))))
        selection.select(nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(prepared, [logs[1].id], "A cancelled selection must not prepare later")
    }
}
