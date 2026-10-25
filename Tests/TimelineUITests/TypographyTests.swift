import AppKit
import Combine
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class TypographyTests: XCTestCase {
    private final class Model: ObservableObject {
        @Published var value = AppTypography()
    }

    private struct Root<Content: View>: View {
        @ObservedObject var model: Model
        let content: Content
        var body: some View { content.environment(\.typography, model.value) }
    }

    private func descendants<T: NSView>(_ type: T.Type, of view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, of: $0) }
    }

    func testSliderGestureKeepsChangesLocalAndPersistsOnlyTheFinalValues() throws {
        let defaults = InMemoryDefaults()
        defaults.set(1.0, forKey: Prefs.uiScale)
        defaults.set(2.0, forKey: Prefs.lineSpacing)
        let adjustment = TypographyAdjustment(defaults: defaults)
        adjustment.setEditing(true)
        for scale in stride(from: 1.0, through: 1.5, by: 0.01) { adjustment.scale = scale }
        adjustment.spacing = 4
        XCTAssertEqual(defaults.double(forKey: Prefs.uiScale), 1)
        XCTAssertEqual(defaults.double(forKey: Prefs.lineSpacing), 2)
        adjustment.setEditing(false)
        XCTAssertEqual(defaults.double(forKey: Prefs.uiScale), 1.5, accuracy: 0.001)
        XCTAssertEqual(defaults.double(forKey: Prefs.lineSpacing), 4)
        adjustment.scale = 1.23 // Keyboard or accessibility adjustment has no drag gesture.
        XCTAssertEqual(defaults.double(forKey: Prefs.uiScale), 1.23)
        XCTAssertEqual(TypographyAdjustment(defaults: defaults).scale, 1.23)
    }

    func testCalendarColumnWidthDoesNotDependOnFontOrOverflow() {
        let size = CGSize(width: 600, height: 480)
        let sparse = CalendarGridMetrics(size: size, counts: Array(repeating: 0, count: 42), scale: 1)
        for scale in [1.2, 1.21, 1.3, 1.5] {
            let dense = CalendarGridMetrics(size: size, counts: Array(repeating: 8, count: 42), scale: scale)
            XCTAssertEqual(dense.columnWidth, sparse.columnWidth)
            XCTAssertGreaterThan(dense.weekHeights.reduce(0, +), size.height)
            XCTAssertLessThanOrEqual(7 * dense.columnWidth + 36 + 4 + CalendarGridMetrics.scrollbarGutter, size.width)
        }
        XCTAssertEqual(sparse.weekHeights.count, 6)
    }

    func testTextResizesWithoutReplacingTheViewParsedSourceOrSelection() async throws {
        let model = Model()
        let source = "## Reading\n\nA **bold** note and [paper](https://example.com)."
        let content = TaskLinkText(source: source, completed: false, color: .primary, fontSize: 13,
                                   edit: {}, open: { _ in }, maxLines: 0, markdown: true)
        let host = NSHostingView(rootView: Root(model: model, content: content))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let original = try XCTUnwrap(descendants(InteractiveTaskText.self, of: host).first)
        let selection = NSRange(location: 0, length: 3)
        original.setSelectedRange(selection)
        for scale in [1.2, 1.3, 1.5, 1.0] {
            model.value = AppTypography(scale: scale, lineSpacing: 4)
            try await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded()
            let text = try XCTUnwrap(descendants(InteractiveTaskText.self, of: host).first)
            XCTAssertTrue(text === original)
            XCTAssertEqual(text.selectedRange(), selection)
            XCTAssertEqual(text.source, source)
            XCTAssertNotNil(text.markdownDocument)
            let paragraph = (text.string as NSString).range(of: "A bold")
            XCTAssertEqual((text.textStorage?.attribute(.font, at: paragraph.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 13 * scale, accuracy: 0.01)
        }
    }

    func testMainCalendarKeepsNativeCellsAndSettlesAbove120Percent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let month = JournalDates.monthStart(Date())
        for day in 0..<28 {
            let task = try XCTUnwrap(store.addParsedTodo("阅读论文 \(day)", on: month))
            store.updateTodo(task.id, scheduledDate: month,
                             dueDate: month.addingTimeInterval(Double(day) * 86400 + 15 * 3600),
                             dueHasTime: true, reminderMinutes: nil, repeatRule: .none,
                             priority: day.isMultiple(of: 2) ? .high : .low)
        }
        let model = Model()
        let content = ContentView(store: store, loginItem: LoginItem())
            .environmentObject(ReminderScheduler(store: store))
            .environmentObject(WorkspaceInteraction())
            .environmentObject(CommandCenter())
            .environmentObject(ToastCenter())
        let host = NSHostingView(rootView: Root(model: model, content: content))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        let initial = Set(descendants(CalendarClickView.self, of: host).map(ObjectIdentifier.init))
        XCTAssertFalse(initial.isEmpty)
        for scale in [1.2, 1.25, 1.3, 1.5, 1.2] {
            model.value = AppTypography(scale: scale)
            try await Task.sleep(nanoseconds: 60_000_000)
            host.layoutSubtreeIfNeeded()
            let cells = descendants(CalendarClickView.self, of: host)
            XCTAssertFalse(initial.intersection(cells.map(ObjectIdentifier.init)).isEmpty, "字号变化保留现有日期格子")
            let widths = cells.map { $0.bounds.width }
            let frames = cells.map { $0.convert($0.bounds, to: host) }
            for _ in 0..<3 {
                try await Task.sleep(nanoseconds: 20_000_000)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(cells.map { $0.bounds.width }, widths)
                XCTAssertEqual(cells.map { $0.convert($0.bounds, to: host) }, frames, "布局稳定后不再抽动")
            }
        }
    }
}
