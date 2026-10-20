import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class TaskTimelineTests: XCTestCase {
    func testConnectorsMeetAcrossSpacingAndStopAtTheFirstAndLastNodes() {
        let size = CGRect(x: 0, y: 0, width: 30, height: 60)
        let first = TaskTimelineConnector(position: .init(hasPrevious: false, hasNext: true)).path(in: size).boundingRect
        let middle = TaskTimelineConnector(position: .init(hasPrevious: true, hasNext: true)).path(in: size).boundingRect
        let last = TaskTimelineConnector(position: .init(hasPrevious: true, hasNext: false)).path(in: size).boundingRect
        XCTAssertEqual(first.minY, size.midY + 6)
        XCTAssertEqual(first.maxY, size.maxY + TaskReorderModel.spacing / 2)
        XCTAssertEqual(middle.minY, -TaskReorderModel.spacing / 2)
        XCTAssertEqual(middle.maxY, first.maxY)
        XCTAssertEqual(last.maxY, size.midY - 6)
        XCTAssertTrue(TaskTimelineConnector(position: .init(hasPrevious: false, hasNext: false)).path(in: size).isEmpty)
    }

    func testTimelineRowsKeepLongTitlesReadableAtLargerTextSizes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let focus = FocusSession()
        focus.store = store
        let tasks = try ["Read the paper #reading", "Compare the results with the previous experiments and write observations", "Write a short review #writing"].map {
            try XCTUnwrap(store.addParsedTodo($0, on: Date()))
        }
        for scale in [1.0, 1.2] {
            let view = VStack(spacing: TaskReorderModel.spacing) {
                ForEach(Array(tasks.enumerated()), id: \.element.id) { index, item in
                    ManagedTaskRow(store: store, date: item.date, task: item.task, requestedEdit: .constant(nil),
                                   timeline: .init(hasPrevious: index > 0, hasNext: index < tasks.count - 1))
                }
            }
            .padding(16).frame(width: 480).background(Palette.background)
            .environmentObject(WorkspaceInteraction()).environment(\.focusSession, focus)
            .environment(\.typography, AppTypography(scale: scale))
            let host = NSHostingView(rootView: view)
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            func titles(_ view: NSView) -> [InteractiveTaskText] {
                (view as? InteractiveTaskText).map { [$0] } ?? view.subviews.flatMap(titles)
            }
            XCTAssertEqual(titles(host).count, tasks.count)
            for title in titles(host) { XCTAssertGreaterThan(title.bounds.width, 100) }
            XCTAssertLessThan(host.fittingSize.height, 350)
            if let destination = ProcessInfo.processInfo.environment["TIMELINE_LIST_SNAPSHOT"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination + "-\(Int(scale * 100)).png"))
            }
        }
    }
}
