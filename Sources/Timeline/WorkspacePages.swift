import AppKit

/// 主窗口：Esc 在笔记 / 日记页上收起窗口（没有文字框先处理它时），和原来独立的笔记窗口一致。
/// 窗口钉在所在屏幕的中央，拖不动；拉边缘缩放时以中心为基准对称缩放，被拉的那条边始终跟着鼠标。
/// 关掉「固定在屏幕中央」后就是普通窗口，可以拖到一边和别的应用并排。
final class MainWindow: QuietWindow {
    var cancel: (() -> Bool)?
    var keepsCentered = true {
        didSet {
            guard keepsCentered != oldValue else { return }
            isMovable = !keepsCentered
            if keepsCentered { setFrame(frame, display: true) }
        }
    }
    /// 用户自己拉出来的大小。换到小屏幕时窗口被压小，回到大屏幕时按它恢复。
    private(set) var preferredSize: NSSize?
    /// 上次居中时所在屏幕的可用区域：变了说明换了屏幕（或屏幕分辨率变了）。
    private var lastArea: NSRect?
    /// 开始拉边时的窗口和鼠标位置，以及拉的是哪几条边（-1 左 / 下，1 右 / 上，0 没拉）。
    private var resizeStart: (frame: NSRect, mouse: NSPoint, edges: (x: CGFloat, y: CGFloat))?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isMovable = false
        isMovableByWindowBackground = false
        NotificationCenter.default.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: self, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginResize() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: self, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resizeStart = nil
                self.preferredSize = self.frame.size
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if cancel?() != true { super.cancelOperation(sender) }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(centered(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(centered(frameRect), display: displayFlag, animate: animateFlag)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        setFrame(NSRect(origin: point, size: frame.size), display: true)
    }

    override func setFrameTopLeftPoint(_ point: NSPoint) {
        setFrame(NSRect(x: point.x, y: point.y - frame.height, width: frame.width, height: frame.height), display: true)
    }

    private func beginResize() {
        let mouse = NSEvent.mouseLocation
        let slop: CGFloat = 12
        func edge(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            abs(value - low) <= slop ? -1 : abs(value - high) <= slop ? 1 : 0
        }
        resizeStart = (frame, mouse, (edge(mouse.x, frame.minX, frame.maxX), edge(mouse.y, frame.minY, frame.maxY)))
    }

    /// 全屏时交给系统；否则把窗口放到它所在屏幕可用区域的中央。
    private func centered(_ proposed: NSRect) -> NSRect {
        guard keepsCentered, !styleMask.contains(.fullScreen) else { return proposed }
        let center = NSPoint(x: proposed.midX, y: proposed.midY)
        guard let area = (NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? screen ?? NSScreen.main)?.visibleFrame else { return proposed }
        var size = proposed.size
        if inLiveResize, let start = resizeStart {
            size = Self.symmetricSize(start: start.frame.size, edges: start.edges, mouseDelta: NSPoint(x: NSEvent.mouseLocation.x - start.mouse.x, y: NSEvent.mouseLocation.y - start.mouse.y), proposed: proposed.size)
        } else if let preferredSize, let lastArea, lastArea != area {
            // 换到了另一块屏幕：放得下就回到用户拉出来的大小（之前在小屏幕上被压小了）。
            size = NSSize(width: max(size.width, preferredSize.width), height: max(size.height, preferredSize.height))
        }
        lastArea = area
        return Self.centeredFrame(size: size, in: area, minSize: minSize, maxSize: maxSize)
    }

    /// 拉一条边移动 d，宽（高）就变 2d：另一条边同时反向移动，中心不动。没拉的方向沿用系统给的尺寸。
    static func symmetricSize(start: NSSize, edges: (x: CGFloat, y: CGFloat), mouseDelta: NSPoint, proposed: NSSize) -> NSSize {
        NSSize(width: edges.x == 0 ? proposed.width : start.width + 2 * edges.x * mouseDelta.x,
               height: edges.y == 0 ? proposed.height : start.height + 2 * edges.y * mouseDelta.y)
    }

    /// 尺寸夹在最小 / 最大尺寸和屏幕可用区域之间，再放到可用区域正中（取整到像素，避免模糊）。
    static func centeredFrame(size: NSSize, in area: NSRect, minSize: NSSize, maxSize: NSSize) -> NSRect {
        let width = min(max(size.width, minSize.width), maxSize.width, area.width).rounded()
        let height = min(max(size.height, minSize.height), maxSize.height, area.height).rounded()
        return NSRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
    }
}

/// 主窗口的内容：主界面和笔记 / 日记两页叠在一起，一次只显示一页，窗口的位置和大小两页共用。
/// 藏起来的那页视图和状态（草稿、滚动位置、打开的笔记本）都留着，切回来是原样。
/// 每页记住自己的键盘焦点：切走时记下，切回来时还给它，打字不会落进看不见的那页。
@MainActor
final class WorkspacePagesView: NSView {
    private(set) var main: NSView?
    private(set) var notes: NSView?
    private(set) var showsNotes = false
    private weak var mainResponder: NSResponder?
    private weak var notesResponder: NSResponder?

    /// 换上（或释放掉）主界面。
    func setMain(_ view: NSView?) {
        main?.removeFromSuperview()
        main = view
        if let view { add(view) }
        update()
    }

    func setNotes(_ view: NSView) {
        notes?.removeFromSuperview()
        notes = view
        add(view)
        update()
    }

    /// 切到笔记页（`true`）或主界面。
    func show(notes showNotes: Bool) {
        guard showNotes != showsNotes, !showNotes || notes != nil else { return }
        let leaving = showsNotes ? notes : main
        // 文字框在编辑时，焦点在共用的字段编辑器上（离开后它会被拿走）：记下文字框本身。
        let current = window?.firstResponder
        let field = (current as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil }
        if let responder = field ?? current as? NSView, let leaving, responder.isDescendant(of: leaving) {
            if showsNotes { notesResponder = responder } else { mainResponder = responder }
        }
        showsNotes = showNotes
        update()
        guard let window else { return }
        let page = showNotes ? notes : main
        let saved = showNotes ? notesResponder : mainResponder
        if let saved = saved as? NSView, let page, saved.isDescendant(of: page), saved.window === window {
            window.makeFirstResponder(saved)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    private func add(_ view: NSView) {
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    private func update() {
        main?.isHidden = showsNotes
        notes?.isHidden = !showsNotes
    }
}
