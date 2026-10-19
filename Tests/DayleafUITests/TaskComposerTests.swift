import AppKit
import SwiftUI
import XCTest
import DayleafCore
@testable import Dayleaf

@MainActor
final class TaskComposerTests: XCTestCase {
    func testComposerFitsNarrowRowsWithCreationMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        var options = TaskCreationOptions()
        options.priority = .high
        for width in [308.0, 400] {
            let host = NSHostingView(rootView: TaskComposerRow(store: store, text: .constant("Read the paper #reading"), focused: .constant(false), options: .constant(options), compact: width < 400, submit: {} ).frame(width: width))
            let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setContentSize(NSSize(width: width, height: host.fittingSize.height))
            host.layoutSubtreeIfNeeded()
            func fields(_ view: NSView) -> [TaskTextField] {
                (view as? TaskTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            if width < 400 {
                func editors(_ view: NSView) -> [ImagePasteTextView] {
                    (view as? ImagePasteTextView).map { [$0] } ?? view.subviews.flatMap(editors)
                }
                let editor = try XCTUnwrap(editors(host).first)
                XCTAssertGreaterThan(try XCTUnwrap(editor.enclosingScrollView).frame.width, 80)
            } else {
                XCTAssertGreaterThan(try XCTUnwrap(fields(host).first).frame.width, 80)
            }
            XCTAssertLessThan(host.fittingSize.height, 85)
            if let destination = ProcessInfo.processInfo.environment["DAYLEAF_COMPOSER_SNAPSHOT"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination + "-\(Int(width)).png"))
            }
            window.contentView = nil
            window.close()
        }
    }
}
