import AppKit
import SwiftUI
import XCTest
import DayleafCore
@testable import Dayleaf

@MainActor
final class TaskRowLayoutTests: XCTestCase {
    func testDeadlineAndCombinedFocusControlLeaveRoomForTheTitle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let day = Date()
        let task = try XCTUnwrap(store.addParsedTodo("Read the paper #reading", on: day))
        let focus = FocusSession()
        focus.store = store
        for (width, scale) in [(400.0, 1.0), (400.0, 1.2), (520.0, 1.5)] {
            let view = ManagedTaskRow(store: store, date: task.date, task: task.task, requestedEdit: .constant(nil))
                .environmentObject(WorkspaceInteraction())
                .environment(\.focusSession, focus)
                .environment(\.typography, AppTypography(scale: scale))
                .frame(width: width)
            let host = NSHostingView(rootView: view)
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 140), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            func titles(_ root: NSView) -> [InteractiveTaskText] {
                (root as? InteractiveTaskText).map { [$0] } ?? root.subviews.flatMap(titles)
            }
            let title = try XCTUnwrap(titles(host).first)
            XCTAssertGreaterThan(title.bounds.width, 80)
            XCTAssertLessThan(host.fittingSize.height, 120)
            if let destination = ProcessInfo.processInfo.environment["DAYLEAF_ROW_SNAPSHOT"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination + "-\(Int(width))-\(Int(scale * 100)).png"))
            }
            window.contentView = nil
            window.close()
        }
    }
}
