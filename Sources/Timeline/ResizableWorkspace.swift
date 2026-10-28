import AppKit
import SwiftUI

enum ResizeAxis { case horizontal, vertical, both }

struct WorkspaceDimensions {
    let size: CGSize
    let left: CGFloat
    let tasksVisible: Bool
    /// 窗口过窄时清单与月历不再并排：清单展开则独占整个区域。
    static let narrowWidth: CGFloat = 860
    var narrow: Bool { size.width < Self.narrowWidth }

    init(size: CGSize, leftFraction: Double, tasksVisible: Bool = true) {
        self.size = size
        self.tasksVisible = tasksVisible
        let minimumLeft = min(300, size.width * 0.4)
        let minimumRight = min(460, size.width * 0.45)
        if tasksVisible, size.width < Self.narrowWidth {
            left = size.width
        } else {
            left = tasksVisible ? min(max(size.width * leftFraction, minimumLeft), size.width - minimumRight) : 0
        }
    }

    var tasksFrame: CGRect { CGRect(x: 0, y: 0, width: left, height: size.height) }
    var calendarFrame: CGRect { CGRect(x: left, y: 0, width: size.width - left, height: size.height) }

    func moving(_ delta: CGSize) -> WorkspaceDimensions {
        WorkspaceDimensions(size: size, leftFraction: (left + delta.width) / max(1, size.width), tasksVisible: tasksVisible)
    }
}

/// 拖动窗口边缘缩放时的策略：跟手第一。窗口一变，SwiftUI 要重算清单和月历的几百个视图节点（单次 100ms 以上），
/// 跟不上手的速度，所以拖动开始时先把内容拍成一张**预先模糊好的图**盖在上面，内容的布局冻结不动；
/// 拖动过程中窗口边缘只是移动、图只是被裁掉或露出底色，没有任何重排；松手后去掉图，内容一次性重排到最终大小。
enum LiveResize {
    /// 内容该用哪个尺寸排版：没在缩放就是窗口的真实尺寸，缩放中是冻结的尺寸。
    static func layoutSize(actual: CGSize, frozen: CGSize?) -> CGSize { frozen ?? actual }

    /// 模糊半径（点）。
    static let blurRadius: CGFloat = 7

    /// 把 `rect` 范围内的画面拍下来并模糊一次（之后拖动时不再有任何绘制开销）。失败返回 nil。
    @MainActor
    static func blurredSnapshot(of view: NSView, rect: NSRect) -> NSImage? {
        guard rect.width > 1, rect.height > 1, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        guard let input = CIImage(bitmapImageRep: rep) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / max(1, rect.width)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(blurRadius * scale))
            .cropped(to: input.extent)
        let output = NSCIImageRep(ciImage: blurred)
        let image = NSImage(size: rect.size)
        output.size = rect.size
        image.addRepresentation(output)
        return image
    }
}

/// 告诉 SwiftUI 所在窗口是不是正在被用户拖动缩放；开始时顺便把这个视图所在区域拍成模糊图交给回调。
struct LiveResizeObserver: NSViewRepresentable {
    let changed: (_ live: Bool, _ snapshot: NSImage?) -> Void

    func makeNSView(context: Context) -> LiveResizeView {
        let view = LiveResizeView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: LiveResizeView, context: Context) { view.changed = changed }

    final class LiveResizeView: NSView {
        var changed: ((Bool, NSImage?) -> Void)?
        /// 测试里关掉拍照。
        var takesSnapshot = true
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    var image: NSImage?
                    if self.takesSnapshot, let content = self.window?.contentView {
                        image = LiveResize.blurredSnapshot(of: content, rect: self.convert(self.bounds, to: content))
                    }
                    self.changed?(true, image)
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed?(false, nil) }
            })
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// 主界面：左边待办清单（可收起），右边月历，中间的竖线可以拖动。当天的日志在 ⌘J 打开的 sheet 里。
struct ResizableWorkspace<Tasks: View, Calendar: View>: View {
    @AppStorage("workspaceLeftFraction") private var leftFraction = 0.36
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOrigin: WorkspaceDimensions?
    @State private var dragPosition: WorkspaceDimensions?
    /// 缩放过程中冻结的布局尺寸；nil 表示没在缩放，按真实尺寸排版。
    @State private var frozenSize: CGSize?
    /// 拖动期间盖在上面的模糊画面。
    @State private var blurred: NSImage?
    /// 最近一次的真实尺寸：开始拖动时内容就冻结在它上面。
    @State private var lastActual: CGSize?
    @Binding var tasksVisible: Bool
    @ViewBuilder let tasks: () -> Tasks
    @ViewBuilder let calendar: () -> Calendar

    var body: some View {
        // 两个面板的内容在 GeometryReader 外面构建：缩放窗口时 GeometryReader 每帧都会重新执行，
        // 放在里面的话，清单分组、月历的 42 格预览每帧都要重算一遍。
        let tasksContent = tasks()
        let calendarContent = calendar()
        return GeometryReader { geometry in
            let size = LiveResize.layoutSize(actual: geometry.size, frozen: frozenSize)
            let layout = dragPosition ?? WorkspaceDimensions(size: size, leftFraction: leftFraction, tasksVisible: tasksVisible)
            ZStack(alignment: .topLeading) {
                if tasksVisible {
                    tasksContent.frame(width: layout.tasksFrame.width, height: layout.tasksFrame.height).clipped()
                }
                if !(tasksVisible && layout.narrow) {
                    calendarContent.frame(width: layout.calendarFrame.width, height: layout.calendarFrame.height)
                        .clipped().offset(x: layout.left)
                }
                if tasksVisible, !layout.narrow {
                    handle(layout: layout).frame(width: 12, height: layout.size.height)
                        .offset(x: layout.left - 6)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: tasksVisible)
            .onAppear { lastActual = geometry.size }
            .onChange(of: geometry.size) { lastActual = $0 }
        }
        .clipped()
        .overlay(alignment: .topLeading) {
            if frozenSize != nil {
                ZStack(alignment: .topLeading) {
                    Palette.background
                    if let blurred { Image(nsImage: blurred).interpolation(.none) }
                }
                .allowsHitTesting(false)
            }
        }
        .background(LiveResizeObserver { live, snapshot in
            // 开始拖动：内容冻结在拖动前的尺寸，盖上模糊画面；松手：全部撤掉，内容按真实尺寸重排一次。
            frozenSize = live ? lastActual : nil
            blurred = live ? snapshot : nil
        })
    }

    private func handle(layout: WorkspaceDimensions) -> some View {
        ResizeHandle(axis: .horizontal, begin: {
            NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
            dragOrigin = layout
        }, change: { delta in
            dragPosition = (dragOrigin ?? layout).moving(delta)
        }, end: {
            if let position = dragPosition, tasksVisible { leftFraction = position.left / max(1, position.size.width) }
            dragPosition = nil
            dragOrigin = nil
        })
    }
}

struct ResizeHandle: NSViewRepresentable {
    let axis: ResizeAxis
    let begin: () -> Void
    let change: (CGSize) -> Void
    let end: () -> Void

    func makeNSView(context: Context) -> ResizeHandleView { ResizeHandleView() }
    func updateNSView(_ view: ResizeHandleView, context: Context) {
        view.axis = axis
        view.begin = begin
        view.change = change
        view.end = end
        view.toolTip = axis == .both ? "任意方向拖动，同时调整三个面板" : "拖动调整面板大小"
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel(view.toolTip)
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

final class ResizeHandleView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    var axis: ResizeAxis = .both
    var begin: (() -> Void)?
    var change: ((CGSize) -> Void)?
    var end: (() -> Void)?
    private var origin: NSPoint?
    private var hovered = false
    private var tracking: NSTrackingArea?

    override func resetCursorRects() {
        let cursor: NSCursor = axis == .both ? .crosshair : (axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { origin = event.locationInWindow; begin?() }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        change?(CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y))
    }
    override func mouseUp(with event: NSEvent) { mouseDragged(with: event); origin = nil; end?() }

    override func draw(_ dirtyRect: NSRect) {
        (hovered ? NativePalette.accent : NativePalette.line).setFill()
        switch axis {
        case .horizontal:
            NSBezierPath(rect: NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)).fill()
        case .vertical:
            NSBezierPath(rect: NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)).fill()
        case .both:
            let inset: CGFloat = hovered ? 3 : 8
            NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 4, yRadius: 4).fill()
        }
    }
}
