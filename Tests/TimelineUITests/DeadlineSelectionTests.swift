import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class DeadlineSelectionTests: XCTestCase {
    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 19) -> Date {
        JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testClockUsesTwelveHourTimeAndPreservesDateAndMinutes() {
        let midnight = DeadlineSelection.time(date(15, 37), hour: 12, pm: false)
        XCTAssertEqual(midnight, date(0, 37))
        XCTAssertEqual(DeadlineSelection.time(midnight, pm: true), date(12, 37))
        XCTAssertEqual(DeadlineSelection.time(date(23, 59), hour: 1), date(13, 59))
        XCTAssertEqual(DeadlineSelection.time(date(23, 59), minute: 0), date(23))
        XCTAssertEqual(DeadlineSelection.day(date(0, day: 31), keepingTime: date(15, 37)), date(15, 37, day: 31))
    }

    func testDialHitTestingCoversAllHoursAndExactMinutes() {
        for minute in 0..<60 {
            let angle = Double(minute) / 60 * 2 * Double.pi
            let point = CGPoint(x: 83 + sin(angle) * 64, y: 83 - cos(angle) * 64)
            XCTAssertEqual(DeadlineSelection.dialValue(at: point, size: 166, minutes: true), minute)
            if minute.isMultiple(of: 5) {
                XCTAssertEqual(DeadlineSelection.dialValue(at: point, size: 166, minutes: false), minute == 0 ? 12 : minute / 5)
            }
        }
    }

    func testHandsCanBeSelectedIndividuallyAndManualEditsKeepCurrentPeriod() {
        let value = date(15, 37)
        XCTAssertEqual(DeadlineSelection.hand(at: DeadlineSelection.endpoint(date: value, minutes: false), date: value), false)
        XCTAssertEqual(DeadlineSelection.hand(at: DeadlineSelection.endpoint(date: value, minutes: true), date: value), true)
        var current = value
        let binding = Binding(get: { current }, set: { current = $0 })
        let hours = DeadlineTextInput(due: binding, component: .hour)
        hours.apply("11")
        XCTAssertEqual(current, date(23, 37))
        current = DeadlineSelection.time(current, pm: false)
        hours.apply("11")
        XCTAssertEqual(current, date(11, 37), "An editing callback cannot restore the old PM value")
        DeadlineTextInput(due: binding, component: .day).apply("2026-10-31")
        XCTAssertEqual(current, date(11, 37, day: 31))
        DeadlineTextInput(due: binding, component: .minute).apply("99")
        XCTAssertEqual(current, date(11, 37, day: 31))
        let field = NSTextField()
        field.stringValue = "2026-10-19"
        let coordinator = DeadlineTextInput(due: binding, component: .day).makeCoordinator()
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(current, date(11, 37, day: 31), "Stale text must not undo a calendar click on blur")
        XCTAssertEqual(field.stringValue, "2026-10-31")
    }

    func testCalendarAndOptionalClockStayCompactAndKeepManualDateFields() throws {
        for timed in [false, true] {
            let view = DeadlineSelectionView(due: .constant(date(15, 37)), timed: .constant(timed))
                .environment(\.locale, Locale(identifier: "en_US"))
                .padding(14)
                .background(Palette.card)
            let host = NSHostingView(rootView: view)
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: timed ? 438 : 252, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, timed ? 438 : 252, accuracy: 1)
            XCTAssertLessThan(host.fittingSize.height, 330)
            func pickers(_ view: NSView) -> [NSDatePicker] {
                (view as? NSDatePicker).map { [$0] } ?? view.subviews.flatMap(pickers)
            }
            XCTAssertTrue(pickers(host).isEmpty, "No native date picker can open a duplicate calendar")
            func inputs(_ view: NSView) -> [NSTextField] {
                let fields = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
                return fields + view.subviews.flatMap(inputs)
            }
            XCTAssertEqual(inputs(host).count, timed ? 3 : 1)
            if let destination = ProcessInfo.processInfo.environment["TIMELINE_DEADLINE_SNAPSHOT"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination + (timed ? "-clock" : "-date") + ".png"))
            }
            window.contentView = nil
            window.close()
        }
    }
}
