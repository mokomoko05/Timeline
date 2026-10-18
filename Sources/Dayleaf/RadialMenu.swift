import AppKit
import SwiftUI
import DayleafCore

/// 环形菜单里的一项。
struct RadialItem: Identifiable {
    let id: String
    let symbol: String
    let title: String
    var destructive = false
    /// 开着的开关（比如已固定）：用强调色。
    var active = false
    let action: () -> Void
}

/// 环形菜单的几何：以「三点」按钮为圆心，向左展开成一段扇形环（按钮在行的最右边，右边是拖动把手，所以不向右展开）。
/// 角度是数学角度：0 = 右，90 = 上，180 = 左。
enum RadialLayout {
    static let radius: CGFloat = 58
    static let itemSize: CGFloat = 32
    static let hubRadius: CGFloat = 14
    static let fanStart = 92.0
    static let fanEnd = 268.0

    /// 浮层大小，以及圆心在浮层里的位置（从左上角算）。
    static let panelSize = NSSize(width: 150, height: 190)
    static let hub = CGPoint(x: 128, y: 110)

    static func angles(count: Int) -> [Double] {
        guard count > 1 else { return count == 1 ? [180] : [] }
        let step = (fanEnd - fanStart) / Double(count - 1)
        return (0..<count).map { fanStart + step * Double($0) }
    }

    /// 第 index 项相对圆心的偏移（视图坐标，y 向下）。
    static func offset(index: Int, count: Int) -> CGSize {
        let angle = angles(count: count)[index] * .pi / 180
        return CGSize(width: cos(angle) * radius, height: -sin(angle) * radius)
    }

    /// 鼠标（相对圆心，屏幕坐标，y 向上）还算不算在菜单上：圆心附近，或者扇形环范围内（留一点余量，免得边缘一抖就收起来）。
    static func contains(_ v: CGPoint) -> Bool {
        let distance = hypot(v.x, v.y)
        if distance <= hubRadius + 6 { return true }
        guard distance <= radius + itemSize / 2 + 4 else { return false }
        var angle = atan2(v.y, v.x) * 180 / .pi
        if angle < 0 { angle += 360 }
        return angle >= fanStart - 8 && angle <= fanEnd + 8
    }

    /// 鼠标指着第几项（没有指着任何一项为 nil）。
    static func item(at v: CGPoint, count: Int) -> Int? {
        for index in 0..<count {
            let offset = Self.offset(index: index, count: count)
            // 视图坐标 y 向下，屏幕坐标 y 向上。
            if hypot(v.x - offset.width, v.y + offset.height) <= itemSize / 2 + 3 { return index }
        }
        return nil
    }
}

/// 环形菜单的动画：展开利索一点（弹性很小），收回更快、不错开。
enum RadialMotion {
    static let expand = Animation.spring(response: 0.18, dampingFraction: 0.78)
    static let collapse = Animation.easeIn(duration: 0.1)
    /// 收回动画的时长，之后才真正关掉浮层。
    static let collapseDuration: TimeInterval = 0.11
}

@MainActor
final class RadialMenuModel: ObservableObject {
    let items: [RadialItem]
    @Published var hovered: Int?
    /// 展开着（true）还是正在收回圆心（false）：鼠标一离开就收，收的过程中鼠标回来又会展开。
    @Published var expanded = false
    var choose: (Int) -> Void = { _ in }

    init(items: [RadialItem]) { self.items = items }
}

/// 展开的环形菜单：一段带质感的扇形环，上面是各个操作；指着哪个，上方显示它的名字。
struct RadialMenuView: View {
    @ObservedObject var model: RadialMenuModel
    private var appeared: Bool { model.expanded }

    private var hub: CGPoint { RadialLayout.hub }

    var body: some View {
        ZStack(alignment: .topLeading) {
            band
            hubView
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                itemView(item, index: index)
            }
            if let hovered = model.hovered, model.items.indices.contains(hovered) {
                Text(LocalizedStringKey(model.items[hovered].title))
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
                    .position(x: RadialLayout.panelSize.width / 2, y: 14)
                    .transition(.opacity)
            }
        }
        .frame(width: RadialLayout.panelSize.width, height: RadialLayout.panelSize.height, alignment: .topLeading)
        .animation(Motion.reduced ? nil : .easeOut(duration: 0.08), value: model.hovered)
        .onAppear { model.expanded = true }
        .accessibilityElement(children: .contain).accessibilityLabel("操作菜单")
    }

    /// 底下的扇形环：厚一点的半透明带子，有高光边和投影。
    private var band: some View {
        let path = Path { path in
            // SwiftUI 的角度是顺时针、y 向下，所以数学角度取负。
            path.addArc(center: hub, radius: RadialLayout.radius,
                        startAngle: .degrees(-RadialLayout.fanStart), endAngle: .degrees(-RadialLayout.fanEnd), clockwise: true)
        }
        let shape = path.strokedPath(StrokeStyle(lineWidth: RadialLayout.itemSize + 12, lineCap: .round))
        return shape
            .fill(LinearGradient(colors: [Palette.card, Palette.background], startPoint: .topTrailing, endPoint: .bottomLeading))
            .overlay(shape.stroke(LinearGradient(colors: [Color.white.opacity(0.35), Palette.line], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.32), radius: 9, y: 4)
            .scaleEffect(appeared ? 1 : 0.4, anchor: UnitPoint(x: hub.x / RadialLayout.panelSize.width, y: hub.y / RadialLayout.panelSize.height))
            .opacity(appeared ? 1 : 0)
            .animation(Motion.reduced ? nil : (appeared ? RadialMotion.expand : RadialMotion.collapse), value: appeared)
    }

    private var hubView: some View {
        Circle().fill(LinearGradient(colors: [Palette.soft, Palette.card], startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.4), Palette.line], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .overlay(Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.muted))
            .frame(width: RadialLayout.hubRadius * 2, height: RadialLayout.hubRadius * 2)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
            .position(hub)
    }

    private func itemView(_ item: RadialItem, index: Int) -> some View {
        let offset = RadialLayout.offset(index: index, count: model.items.count)
        let hovered = model.hovered == index
        let tint: Color = item.destructive ? Palette.deadline : (item.active ? Palette.accent : Palette.ink)
        return Button { model.choose(index) } label: {
            Image(systemName: item.symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(tint)
                .frame(width: RadialLayout.itemSize, height: RadialLayout.itemSize)
                .background(Circle().fill(LinearGradient(colors: hovered ? [Palette.soft, Palette.card] : [Palette.card, Palette.background], startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().strokeBorder(hovered ? AnyShapeStyle(tint.opacity(0.7))
                                                       : AnyShapeStyle(LinearGradient(colors: [Color.white.opacity(0.3), Palette.line], startPoint: .top, endPoint: .bottom)),
                                               lineWidth: hovered ? 1.5 : 0.75))
                .shadow(color: .black.opacity(hovered ? 0.4 : 0.22), radius: hovered ? 5 : 2.5, y: hovered ? 3 : 1.5)
                .scaleEffect(hovered ? 1.14 : 1)
        }
        .buttonStyle(.plain)
        .position(x: hub.x + (appeared ? offset.width : 0), y: hub.y + (appeared ? offset.height : 0))
        .scaleEffect(appeared ? 1 : 0.3, anchor: .center)
        .opacity(appeared ? 1 : 0)
        .animation(Motion.reduced ? nil : (appeared ? RadialMotion.expand.delay(Double(index) * 0.012) : RadialMotion.collapse), value: appeared)
        .accessibilityLabel(item.title)
    }
}

private final class RadialPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// 打开、跟踪、收起环形菜单。鼠标位置由定时器直接读取（浮层不是前台窗口，悬停事件不可靠），所以不依赖 SwiftUI 的 onHover。
@MainActor
final class RadialMenuController {
    static let shared = RadialMenuController()

    private var panel: RadialPanel?
    private var model: RadialMenuModel?
    private var timer: Timer?
    private var hubScreen = CGPoint.zero
    private var closing: Task<Void, Never>?
    /// 正在收回（鼠标已经离开，动画放完就关）。
    private(set) var isCollapsing = false
    private var pendingOpen: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// 鼠标停在三点上多久后展开。
    static let openDelay: Duration = .milliseconds(110)

    var isOpen: Bool { panel?.isVisible == true }
    var openItems: [RadialItem] { model?.items ?? [] }
    var hoveredIndex: Int? { model?.hovered }

    /// 鼠标移到三点按钮上：稍等一下再展开，快速掠过不会弹出来。
    func scheduleOpen(items: @escaping () -> [RadialItem], anchor: NSView?) {
        pendingOpen?.cancel()
        pendingOpen = Task { [weak self, weak anchor] in
            try? await Task.sleep(for: Self.openDelay)
            guard !Task.isCancelled, let self, let anchor else { return }
            self.present(items: items(), anchor: anchor)
        }
    }

    func cancelOpen() { pendingOpen?.cancel(); pendingOpen = nil }

    func present(items: [RadialItem], anchor: NSView) {
        cancelOpen()
        guard !items.isEmpty, let window = anchor.window else { return }
        dismiss()
        let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        present(items: items, hubAt: CGPoint(x: frame.midX, y: frame.midY), parent: window)
    }

    /// 直接指定圆心的屏幕位置（测试用）。
    func present(items: [RadialItem], hubAt center: CGPoint, parent: NSWindow? = nil) {
        dismiss()
        let model = RadialMenuModel(items: items)
        model.choose = { [weak self] index in self?.choose(index) }
        self.model = model
        hubScreen = center
        let size = RadialLayout.panelSize
        let host = NSHostingView(rootView: LocalizedRoot { RadialMenuView(model: model) })
        host.setFrameSize(size)
        let panel = RadialPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // 圆心对准三点按钮：浮层的左上角 = 圆心 − 圆心在浮层里的位置（屏幕坐标 y 向上）。
        panel.setFrameOrigin(NSPoint(x: center.x - RadialLayout.hub.x, y: center.y - (size.height - RadialLayout.hub.y)))
        if Headless.active { panel.alphaValue = 0; panel.ignoresMouseEvents = true }
        parent?.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
        self.panel = panel
        isCollapsing = false
        startTracking()
    }

    func dismiss() {
        cancelOpen()
        closing?.cancel()
        closing = nil
        isCollapsing = false
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        model = nil
    }

    private func choose(_ index: Int) {
        guard let items = model?.items, items.indices.contains(index) else { return }
        let action = items[index].action
        dismiss()
        action()
    }

    private func startTracking() {
        guard !Headless.active else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 90, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(mouse: NSEvent.mouseLocation) }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    /// 根据鼠标位置更新「指着哪一项」。鼠标一离开就立刻开始收回，动画放完关掉浮层；收的过程中鼠标回来就反向展开。
    func update(mouse: CGPoint) {
        guard let model else { return }
        let relative = CGPoint(x: mouse.x - hubScreen.x, y: mouse.y - hubScreen.y)
        let inside = RadialLayout.contains(relative)
        let hovered = inside ? RadialLayout.item(at: relative, count: model.items.count) : nil
        if model.hovered != hovered { model.hovered = hovered }
        if inside {
            guard isCollapsing else { return }
            isCollapsing = false
            closing?.cancel()
            closing = nil
            model.expanded = true
        } else if !isCollapsing {
            isCollapsing = true
            model.expanded = false
            closing = Task { [weak self] in
                try? await Task.sleep(for: .seconds(RadialMotion.collapseDuration))
                guard !Task.isCancelled else { return }
                self?.dismiss()
            }
        }
    }
}

/// 一行右边的「三点」按钮：鼠标停上去展开环形菜单，点一下也展开；右键有同样的操作。
struct RadialMenuButton: View {
    @Environment(\.typography) private var typography
    let items: () -> [RadialItem]
    var help = "更多操作"
    @State private var anchor: AnchorBox = AnchorBox()

    var body: some View {
        Button { RadialMenuController.shared.present(items: items(), anchor: anchor.view ?? NSView()) } label: {
            Image(systemName: "ellipsis").font(.system(size: typography.pt(12), weight: .bold)).frame(width: 18, height: 18)
        }
        .buttonStyle(HitAreaButtonStyle())
        .foregroundStyle(Palette.muted)
        .background(AnchorReader(box: anchor))
        .onHover { inside in
            if inside { RadialMenuController.shared.scheduleOpen(items: items, anchor: anchor.view) } else { RadialMenuController.shared.cancelOpen() }
        }
        .help(help).accessibilityLabel(help)
        .accessibilityActions {
            ForEach(items()) { item in Button(item.title, action: item.action) }
        }
    }
}

final class AnchorBox {
    weak var view: NSView?
}

/// 取到所在位置的 NSView，用来算屏幕坐标。
struct AnchorReader: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}
