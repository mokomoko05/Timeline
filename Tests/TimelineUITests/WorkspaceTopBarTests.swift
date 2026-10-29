import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class WorkspaceTopBarTests: XCTestCase {
    func testTooltipsFollowEachConfiguredShortcutAndResetImmediately() {
        let defaults = InMemoryDefaults()
        let labels = WorkspaceShortcutLabels(defaults: defaults)
        for (index, action) in HotKeyAction.allCases.enumerated() {
            let custom = HotKeyBinding(keyCode: kVK_ANSI_K, modifiers: cmdKey | (index.isMultiple(of: 2) ? shiftKey : optionKey))
            HotKeyStore.save(custom, for: action, defaults: defaults)
            NotificationCenter.default.post(name: .timelineHotKeysChanged, object: nil)
            XCTAssertEqual(labels.help("隐藏", action: action), AppLocalized("隐藏") + " · " + custom.label)
            HotKeyStore.save(nil, for: action, defaults: defaults)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            XCTAssertEqual(labels.help("隐藏", action: action), AppLocalized("隐藏") + " · " + action.defaultBinding.label)
        }
    }

    func testActualMainAndNotesCloseButtonsAlignAndAllPanelsFitAfterResizing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let previousSync = AppRouter.cloudSync
        let sync = CloudSyncController(store: store, defaults: InMemoryDefaults())
        AppRouter.cloudSync = sync
        defer { AppRouter.cloudSync = previousSync }
        let syncWidth = NSHostingView(rootView: WorkspaceSyncButton()).fittingSize.width
        let main = NSHostingView(rootView: LocalizedRoot {
            ContentView(store: store, loginItem: LoginItem())
                .environmentObject(ReminderScheduler(store: store))
                .environmentObject(WorkspaceInteraction())
                .environmentObject(CommandCenter())
                .environmentObject(ToastCenter())
        })
        let notes = NSHostingView(rootView: LocalizedRoot {
            UnifiedNotesView(store: store, workspace: NotesWorkspaceNavigation(), nav: NotesNavigation(defaults: InMemoryDefaults()),
                             close: {}, reveal: { _ in }, openDay: { _ in })
        })
        let pages = WorkspacePagesView()
        let window = MainWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 820),
                                styleMask: MainWindow.workspaceStyle, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.keepsCentered = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = true
        }
        window.contentView = pages
        pages.setMain(main)
        pages.setNotes(notes)
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.canBecomeMain)

        for size in [NSSize(width: 1280, height: 820), NSSize(width: 640, height: 560), NSSize(width: 1000, height: 700)] {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
            pages.show(.main)
            try await Task.sleep(for: .milliseconds(100))
            pages.layoutSubtreeIfNeeded()
            var closeFrames: [NSRect] = []
            for (name, host, page) in [("main", main as NSView, WorkspacePage.main), ("notes", notes as NSView, WorkspacePage.notes)] {
                pages.show(page)
                try await Task.sleep(for: .milliseconds(100))
                pages.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                let closeRegion = NSRect(x: host.bounds.width - 48, y: 0, width: 40, height: 32)
                let close = try XCTUnwrap(inkBounds(in: bitmap, region: closeRegion, scale: scale), "X 必须实际画出")
                closeFrames.append(close)
                XCTAssertLessThan(close.maxY / scale, 28, "关闭按钮必须位于紧凑顶栏内，上方不再保留空标题栏")
                XCTAssertGreaterThanOrEqual(close.minY / scale, host.bounds.height - window.contentLayoutRect.maxY,
                                            "X 不能挤进原生标题栏")
                if page == .main {
                    // 对实际像素检查六个独立图标，防止按钮被标题栏遮挡或在最小窗口被挤掉。
                    for index in 0..<6 {
                        let region = NSRect(x: 16 + syncWidth + 8 + CGFloat(index) * 34, y: close.minY / scale - 2,
                                            width: 28, height: close.height / scale + 4)
                        XCTAssertNotNil(inkBounds(in: bitmap, region: region, scale: scale), "面板按钮 \(index) 必须实际画出")
                    }
                }
                if let output = ProcessInfo.processInfo.environment["TIMELINE_TOPBAR_PREVIEW"] {
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(output)/\(name)-\(Int(size.width)).png"))
                }
            }
            XCTAssertEqual(closeFrames[0], closeFrames[1], "缩放后主界面和笔记界面的 X 仍在同一位置")
        }
    }

    /// 和同一行的空白背景比较；适用于浅色、深色主题，也不会把水平分隔线当作图标。
    private func inkBounds(in bitmap: NSBitmapImageRep, region: NSRect, scale: CGFloat) -> NSRect? {
        var result: NSRect?
        for y in max(0, Int(region.minY * scale))..<min(bitmap.pixelsHigh, Int(region.maxY * scale)) {
            let start = max(0, Int(region.minX * scale))
            guard let background = bitmap.colorAt(x: start, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            for x in start..<min(bitmap.pixelsWide, Int(region.maxX * scale)) {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let contrast = max(abs(pixel.redComponent - background.redComponent),
                                   abs(pixel.greenComponent - background.greenComponent),
                                   abs(pixel.blueComponent - background.blueComponent))
                if contrast > 0.15 {
                    let point = NSRect(x: x, y: y, width: 1, height: 1)
                    result = result.map { $0.union(point) } ?? point
                }
            }
        }
        return result
    }
}
