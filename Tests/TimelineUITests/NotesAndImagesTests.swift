import AppKit
import SwiftUI
import XCTest
@testable import Timeline
@testable import TimelineCore

@MainActor
final class NotesAndImagesTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    override func setUp() async throws { _ = NSApplication.shared }

    private func makeStore() -> JournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JournalStore(directory: directory)
    }

    // MARK: - 从清单打开某个任务的笔记

    func testTaskWithoutNotesStillHasATopicSoNotesOpenOnIt() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.addParsedTodo("读论文 #论文", on: day)).id
        XCTAssertFalse(store.noteTopics().contains { $0.id == id }, "还没有笔记，不在笔记主题列表里")
        let topic = try XCTUnwrap(store.noteTopic(for: id), "但可以直接打开它的笔记页")
        XCTAssertEqual(topic.count, 0)
        XCTAssertEqual(topic.number, 1)
        XCTAssertEqual(topic.tags, ["论文"])
        XCTAssertFalse(topic.deleted)
        XCTAssertNil(store.noteTopic(for: UUID()), "不存在的任务没有主题")

        let nav = NotesNavigation()
        nav.open(task: id)
        nav.validate(in: store)
        XCTAssertEqual(nav.selection, id, "没有笔记的任务也能停留，不会被退回别处")

        _ = try store.quickLog("第一条", taskID: id, on: day)
        XCTAssertEqual(store.noteTopic(for: id)?.count, 1, "有了笔记就是正常的主题")
    }

    func testNotesViewRendersAnEmptyTaskPageWithItsComposer() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.addParsedTodo("写周报", on: day)).id
        let nav = NotesNavigation()
        let view = NotesView(store: store, initialSelection: id, nav: nav, reveal: { _ in }, openDay: { _ in }).frame(width: 900, height: 600)
        let host = NSHostingView(rootView: view)
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        Self.keepAlive += [window, host]
        XCTAssertEqual(nav.selection, id, "打开的是这个任务，不是空白页")
    }

    // MARK: - 同一个任务的图片可以左右翻

    func testGalleryCollectsImagesFromAllNotesOfTheSameTaskInOrder() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("读论文", on: day)).id
        let other = try XCTUnwrap(store.addParsedTodo("别的事", on: day)).id
        _ = try store.quickLog("第一天的图", images: ["a.png", "b.png"], taskID: task, on: day, now: day.addingTimeInterval(1))
        _ = try store.quickLog("不相干", images: ["x.png"], taskID: other, on: day, now: day.addingTimeInterval(2))
        _ = try store.quickLog("第二天的图", images: ["c.png"], taskID: task, on: day.addingTimeInterval(86400), now: day.addingTimeInterval(86401))
        _ = try store.quickLog("没图", taskID: task, on: day, now: day.addingTimeInterval(3))
        let second = try XCTUnwrap(store.allLogs().first { $0.log.text == "第二天的图" }).log
        let gallery = store.galleryImages(around: second)
        XCTAssertEqual(gallery.map(\.name), ["a.png", "b.png", "c.png"], "同一个任务的笔记里的图，按时间顺序，不混进别的任务")
        XCTAssertTrue(gallery[0].caption.contains("第一天的图"))
        XCTAssertTrue(gallery[2].caption.hasPrefix("2026-10-08"))

        let loose = try XCTUnwrap(try store.quickLogEntry("没关联任务", images: ["y.png", "z.png"], linkDefault: false, on: day).entry)
        XCTAssertEqual(store.galleryImages(around: loose).map(\.name), ["y.png", "z.png"], "没关联任务就只是这条自己的图")
    }

    func testPreviewGroupsTaskImagesAndKeepsClickedImageWhenEarlierFilesAreMissing() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("读论文", on: day)).id
        _ = try store.quickLog("一", images: ["missing.png", "a.png"], taskID: task, on: day, now: day.addingTimeInterval(1))
        _ = try store.quickLog("二", images: ["b.png", "c.png"], taskID: task, on: day, now: day.addingTimeInterval(2))
        try FileManager.default.createDirectory(at: store.imageURL("a.png").deletingLastPathComponent(), withIntermediateDirectories: true)
        for name in ["a.png", "b.png", "c.png"] { try Data([1]).write(to: store.imageURL(name)) }
        let log = try XCTUnwrap(store.allLogs().first { $0.log.text == "二" }).log
        let viewer = ImageViewerController()
        let urls = viewer.previewURLs(store: store, around: log, index: 1)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["c.png", "a.png", "b.png"])
        XCTAssertTrue(urls.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == task.uuidString })
        XCTAssertTrue(urls.allSatisfy { $0.resolvingSymlinksInPath() == store.imageURL($0.lastPathComponent) })
        XCTAssertFalse(store.unusedImageNames().contains("Preview"), "预览缓存不应被图片清理删除")
        XCTAssertFalse(viewer.isVisible, "准备 Preview 文件不创建应用内窗口")
    }

    func testPreviewSeparatesUnicodeTagsAndHandlesEmptyMissingAndDuplicateImages() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.imageURL("a.png").deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: store.imageURL("a.png"))
        let viewer = ImageViewerController()
        var folders = Set<URL>()
        for tag in ["论文/设计", "会议", "论文-设计"] {
            _ = try store.quickLogEntry("图片", images: ["a.png"], linkDefault: false, tags: [tag], on: day)
            let saved = try XCTUnwrap(store.allLogs().first { $0.log.tags == [tag] }).log
            let urls = viewer.previewURLs(store: store, around: saved, index: 0)
            folders.insert(try XCTUnwrap(urls.first).deletingLastPathComponent())
        }
        XCTAssertEqual(folders.count, 3)
        let draft = store.directory.appendingPathComponent("Preview/Draft")
        XCTAssertTrue(viewer.previewURLs(store: store, names: [], index: 0, folder: draft).isEmpty)
        XCTAssertTrue(viewer.previewURLs(store: store, names: ["missing.png"], index: 0, folder: draft).isEmpty)
        XCTAssertEqual(viewer.previewURLs(store: store, names: ["a.png", "a.png"], index: 9, folder: draft).count, 1)
    }

    func testViewerStartsAtTheClickedImageAndMovesWithinBounds() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addParsedTodo("读论文", on: day)).id
        _ = try store.quickLog("一", images: ["a.png", "b.png"], taskID: task, on: day, now: day.addingTimeInterval(1))
        _ = try store.quickLog("二", images: ["c.png", "d.png"], taskID: task, on: day, now: day.addingTimeInterval(2))
        let log = try XCTUnwrap(store.allLogs().first { $0.log.text == "二" }).log
        let viewer = ImageViewerController()
        addTeardownBlock { viewer.close() }
        viewer.show(store: store, around: log, index: 1)
        XCTAssertTrue(viewer.isVisible, "独立窗口")
        XCTAssertEqual(viewer.model.items.count, 4)
        XCTAssertEqual(viewer.model.current?.name, "d.png", "从点的那张开始：第二条笔记的第 2 张")
        viewer.model.move(1)
        XCTAssertEqual(viewer.model.current?.name, "d.png", "到头了就停住")
        for _ in 0..<5 { viewer.model.move(-1) }
        XCTAssertEqual(viewer.model.current?.name, "a.png", "能翻到这个任务更早的笔记里的图")
        XCTAssertFalse(viewer.model.canGoBack)
        XCTAssertTrue(viewer.model.canGoForward)
    }

    func testNativeGalleryUsesCurrentTagAndZoomResetsOnlyOnImageChange() throws {
        let store = makeStore()
        _ = try store.quickLogEntry("multi", images: ["a.png", "b.png"], linkDefault: false, tags: ["A", "B"], on: day)
        _ = try store.quickLogEntry("only B", images: ["c.png"], linkDefault: false, tags: ["B"], on: day)
        _ = try store.quickLogEntry("only A", images: ["d.png"], linkDefault: false, tags: ["A"], on: day)
        let log = try XCTUnwrap(store.allLogs().first { $0.log.text == "multi" }).log
        let viewer = ImageViewerController()
        defer { viewer.close() }
        viewer.show(store: store, around: log, index: 1, tag: "B")
        XCTAssertEqual(viewer.model.current?.name, "b.png")
        XCTAssertEqual(Set(viewer.model.items.map(\.name)), ["a.png", "b.png", "c.png"])
        viewer.model.zoomIn()
        XCTAssertEqual(viewer.model.zoom, 1.25)
        viewer.model.zoomOut()
        XCTAssertEqual(viewer.model.zoom, 1)
        viewer.model.setZoom(100)
        XCTAssertEqual(viewer.model.zoom, 8)
        viewer.model.setZoom(0)
        XCTAssertEqual(viewer.model.zoom, 0.25)
        viewer.model.fit()
        XCTAssertEqual(viewer.model.zoom, 1)
        viewer.model.zoomIn()
        viewer.model.move(viewer.model.canGoForward ? 1 : -1)
        XCTAssertEqual(viewer.model.zoom, 1)
    }

    func testImageCopyWritesImageDataAndZoomViewKeepsImageLoaded() throws {
        let store = makeStore()
        let url = store.imageURL("copy.tiff")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { bounds in
            NSColor.red.setFill(); bounds.fill(); return true
        }
        try XCTUnwrap(image.tiffRepresentation).write(to: url)
        let pasteboard = NSPasteboard(name: .init("image-copy-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(ImageClipboard.copy(url, to: pasteboard))
        XCTAssertTrue(pasteboard.canReadObject(forClasses: [NSImage.self]))
        XCTAssertFalse(ImageClipboard.copy(store.imageURL("missing.png"), to: pasteboard))
        XCTAssertTrue(pasteboard.canReadObject(forClasses: [NSImage.self]), "复制失败保留剪贴板")
        let scroll = ImageZoomScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        scroll.layoutSubtreeIfNeeded()
        scroll.display(url, zoom: 1)
        let original = try XCTUnwrap((scroll.documentView as? NSImageView)?.image)
        let fitted = scroll.magnification
        scroll.display(url, zoom: 2)
        XCTAssertEqual(scroll.magnification, fitted * 2, accuracy: 0.01)
        XCTAssertTrue((scroll.documentView as? NSImageView)?.image === original)
        XCTAssertTrue(scroll.allowsMagnification)
        XCTAssertTrue(scroll.hasHorizontalScroller && scroll.hasVerticalScroller)
        let picture = try XCTUnwrap(scroll.documentView)
        let start = scroll.contentView.bounds.origin.x
        func mouse(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 100), modifierFlags: [], timestamp: 0,
                              windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        picture.mouseDown(with: mouse(.leftMouseDown, x: 100))
        picture.mouseDragged(with: mouse(.leftMouseDragged, x: 148))
        picture.mouseUp(with: mouse(.leftMouseUp, x: 148))
        XCTAssertLessThan(scroll.contentView.bounds.origin.x, start, "放大后的图片可拖动查看")
        if let path = ProcessInfo.processInfo.environment["TIMELINE_IMAGE_VIEWER_SNAPSHOT"] {
            let model = ImageViewerModel()
            model.load([.init(name: "copy.tiff", caption: "阅读笔记")], index: 0)
            let host = NSHostingView(rootView: ImageViewerView(store: store, model: model, openPreview: {}).frame(width: 860, height: 620))
            host.frame = NSRect(x: 0, y: 0, width: 860, height: 620)
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func testViewerIsAMovableResizableWindowWithKeyboardNavigationAndIsReused() throws {
        let store = makeStore()
        let viewer = ImageViewerController()
        addTeardownBlock { viewer.close() }
        viewer.show(store: store, names: ["a.png", "b.png", "c.png"], index: 0)
        let window = try XCTUnwrap(viewer.window)
        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertTrue(window is ScreenBoundWindow)
        XCTAssertTrue(window.styleMask.contains(.resizable), "可以调整大小")
        XCTAssertTrue(window is QuietWindow, "测试里不闪窗口")
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                             characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code)!
        }
        XCTAssertTrue(viewer.handleKey(key(124)))
        XCTAssertEqual(viewer.model.index, 1, "→ 下一张")
        XCTAssertTrue(viewer.handleKey(key(49)))
        XCTAssertEqual(viewer.model.index, 2, "空格也是下一张")
        XCTAssertTrue(viewer.handleKey(key(123)))
        XCTAssertEqual(viewer.model.index, 1, "← 上一张")
        XCTAssertFalse(viewer.handleKey(key(0)), "其他键交给窗口")
        window.sendEvent(key(124))
        XCTAssertEqual(viewer.model.index, 2, "滚动视图获得焦点后，窗口仍处理切图快捷键")
        window.sendEvent(key(24))
        XCTAssertEqual(viewer.model.zoom, 1.25)
        window.sendEvent(key(29))
        XCTAssertEqual(viewer.model.zoom, 1)

        viewer.show(store: store, names: ["z.png"], index: 0)
        XCTAssertTrue(viewer.window === window, "再打开别的图片，复用同一个窗口")
        XCTAssertEqual(viewer.model.items.map(\.name), ["z.png"])
        viewer.show(store: store, names: [], index: 0)
        XCTAssertEqual(viewer.model.items.map(\.name), ["z.png"], "空列表不打开、不清空")
    }

    // MARK: - 点待办以外的地方取消选中

    func testRowRegionsOnlyCountVisiblePartsOfRows() {
        let regions = TaskRowRegions()
        let id = UUID()
        regions.rows = [id: CGRect(x: 0, y: 100, width: 300, height: 40)]
        XCTAssertTrue(regions.containsRow(at: CGPoint(x: 10, y: 120)))
        XCTAssertFalse(regions.containsRow(at: CGPoint(x: 10, y: 160)), "行外面")
        regions.viewport = CGRect(x: 0, y: 110, width: 300, height: 500)
        XCTAssertFalse(regions.containsRow(at: CGPoint(x: 10, y: 105)), "滚到清单可见区域外的部分不算点在行上（比如被标题盖住）")
        XCTAssertTrue(regions.containsRow(at: CGPoint(x: 10, y: 130)))
    }

    func testClickAwayDeselectsAfterTheEventButKeepsANewSelection() async throws {
        let regions = TaskRowRegions()
        let rowID = UUID()
        regions.rows = [rowID: CGRect(x: 0, y: 0, width: 200, height: 40)]
        var selected: UUID? = rowID
        let view = ClickAwayDeselect.ClickAwayView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.regions = regions
        view.selection = { selected }
        view.deselect = { selected = nil }
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        content.addSubview(view)
        Self.keepAlive += [window]
        func click(_ point: NSPoint) -> NSEvent {
            // 窗口坐标原点在左下：内容视图是翻转的，所以 y 要换算。
            NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: point.x, y: 300 - point.y), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        view.handle(click(NSPoint(x: 20, y: 20)))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(selected, rowID, "点在待办上：不取消")

        view.handle(click(NSPoint(x: 300, y: 200)))
        XCTAssertEqual(selected, rowID, "不在按下的那一刻取消：让按钮先用到当前选中的任务")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(selected, "点了待办以外的地方：取消选中")

        selected = rowID
        let other = UUID()
        view.handle(click(NSPoint(x: 300, y: 200)))
        selected = other   // 这次点击本身选中了别的任务（比如日历格子里的事项）
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(selected, other, "这次点击新选中的任务不会被清掉")
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
