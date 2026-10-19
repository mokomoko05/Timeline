import AppKit
import SwiftUI

/// 清单里手动排序的几何计算：被拖的那一行跟着指针走，其他行为它让位。都是纯函数，方便测试。
enum ReorderMath {
    /// 被拖行的位移限制在这一组的范围内，不会拖出组外。
    static func clamp(_ translation: CGFloat, frames: [CGRect], active: Int) -> CGFloat {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return min(max(translation, first.minY - frames[active].minY), last.maxY - frames[active].maxY)
    }

    /// 看被拖行前进方向上的边缘：往上拖看它的上沿，往下拖看它的下沿，越过哪一行的中线，就从那一行的位置插进去。
    /// 不能用被拖行自己的中心：行很高时中心离边缘很远，它的边缘早就压在邻行上了，邻行却还不让位。
    static func targetIndex(frames: [CGRect], active: Int, translation: CGFloat) -> Int {
        let moved = frames[active].offsetBy(dx: 0, dy: translation)
        if translation < 0 {
            return active - frames[..<active].filter { $0.midY > moved.minY }.count
        }
        return active + frames[(active + 1)...].filter { $0.midY < moved.maxY }.count
    }

    /// 第 `index` 行为被拖行让位要移动的距离：被拖行向下越过的行上移，向上越过的行下移，移动量正好是被拖行的高度加行距。
    static func shift(frames: [CGRect], active: Int, target: Int, index: Int, spacing: CGFloat) -> CGFloat {
        guard index != active else { return 0 }
        let step = frames[active].height + spacing
        if target > active, index > active, index <= target { return -step }
        if target < active, index >= target, index < active { return step }
        return 0
    }

    /// 松手后被拖行落进新位置所需的位移。
    static func slotOffset(frames: [CGRect], active: Int, target: Int) -> CGFloat {
        if target > active { return frames[target].maxY - frames[active].maxY }
        if target < active { return frames[target].minY - frames[active].minY }
        return 0
    }

    /// 把 `active` 位置的元素挪到 `target` 位置后的顺序。
    static func moved<T>(_ items: [T], from active: Int, to target: Int) -> [T] {
        var result = items
        result.insert(result.remove(at: active), at: target)
        return result
    }
}

/// 把手发给清单的几个动作。
struct TaskReorderHooks {
    var begin: () -> Bool
    var update: (CGFloat) -> Void
    var end: () -> Void
    var cancel: () -> Void
}

/// 被拖那一行的实时位移，单独成一个对象：它每次鼠标移动都会变，只让被拖的那一行订阅，其他行不用跟着重算。
@MainActor
final class DragOffset: ObservableObject {
    static let idle = DragOffset()
    @Published var value: CGFloat = 0
}

/// 清单排序拖动的状态：哪一行在被拖、拖了多远、其他行该让多少。
@MainActor
final class TaskReorderModel: ObservableObject {
    static let spacing: CGFloat = 6

    /// 各行在清单内容坐标里的位置（不随滚动变化），由布局回传；不需要触发刷新。
    var frames: [UUID: CGRect] = [:]
    /// 给定一个任务，返回它所在分组里全部任务的 id（按显示顺序）。
    var groupProvider: (UUID) -> [UUID] = { _ in [] }
    /// 点把手会选中任务，选中又会触发「滚动到选中项」；排序拖动开始时这个滚动会让清单漂移，所以点把手这一次不滚动。
    var suppressScroll = false
    /// 松手后提交新的顺序。
    var commit: ([UUID]) -> Void = { _ in }

    @Published private(set) var activeID: UUID?
    @Published private(set) var target = 0
    private(set) var dragOffset: CGFloat = 0
    let drag = DragOffset()

    private var group: [UUID] = []
    private var activeIndex = 0
    private var groupFrames: [CGRect] = []

    var isActive: Bool { activeID != nil }

    @discardableResult
    func begin(_ id: UUID) -> Bool {
        guard activeID == nil else { return false }
        let ids = groupProvider(id)
        let rects = ids.compactMap { frames[$0] }
        guard ids.count > 1, rects.count == ids.count, let index = ids.firstIndex(of: id) else { return false }
        group = ids
        groupFrames = rects
        activeIndex = index
        target = index
        dragOffset = 0
        drag.value = 0
        withAnimation(Motion.quick) { activeID = id }
        return true
    }

    /// `translation`：指针相对按下时在清单内容里向下移动的距离（已包含自动滚动的距离）。
    func update(_ translation: CGFloat) {
        guard activeID != nil else { return }
        let clamped = ReorderMath.clamp(translation, frames: groupFrames, active: activeIndex)
        // 指针没动（自动滚动的定时器每帧都会调用）就不要再发布，避免无谓的重绘。
        guard abs(clamped - dragOffset) > 0.01 else { return }
        dragOffset = clamped
        drag.value = clamped
        let newTarget = ReorderMath.targetIndex(frames: groupFrames, active: activeIndex, translation: clamped)
        if newTarget != target { target = newTarget }
    }

    func offset(for id: UUID) -> CGFloat {
        guard activeID != nil, let index = group.firstIndex(of: id) else { return 0 }
        if id == activeID {
            return dragOffset
        }
        return ReorderMath.shift(frames: groupFrames, active: activeIndex, target: target, index: index, spacing: Self.spacing)
    }

    /// 松手立即提交并复位，不等待落位动画。
    func finish() {
        guard activeID != nil else { return }
        complete(order: ReorderMath.moved(group, from: activeIndex, to: target), changed: target != activeIndex)
    }

    func cancel() {
        guard activeID != nil else { return }
        complete(order: group, changed: false)
    }

    private func complete(order: [UUID], changed: Bool) {
        // 顺序和位移在同一刻一起复位，行已经在新位置上，所以看不到跳动。
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if changed { commit(order) }
            activeID = nil
            dragOffset = 0
            drag.value = 0
            group = []
            groupFrames = []
        }
    }
}

private struct TaskReorderKey: EnvironmentKey {
    static let defaultValue: TaskReorderModel? = nil
}

extension EnvironmentValues {
    var taskReorder: TaskReorderModel? {
        get { self[TaskReorderKey.self] }
        set { self[TaskReorderKey.self] = newValue }
    }
}

/// 回传每一行在清单里的位置。
struct TaskRowFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// 清单里的一行：拖动排序时跟随指针或为别的行让位，并回传自己的位置。
    func taskReorderRow(id: UUID, model: TaskReorderModel, space: String) -> some View {
        modifier(TaskReorderShift(id: id, model: model))
            .background(GeometryReader { proxy in
                Color.clear.preference(key: TaskRowFramesKey.self, value: [id: proxy.frame(in: .named(space))])
            })
    }
}

private struct TaskReorderShift: ViewModifier {
    let id: UUID
    @ObservedObject var model: TaskReorderModel

    func body(content: Content) -> some View {
        let active = model.activeID == id
        content
            .background {
                // 阴影画在行的背后，而不是给整行（里面有原生文本控件）加 .shadow，否则每帧都要把整行离屏渲染一遍。
                if active {
                    RoundedRectangle(cornerRadius: 8).fill(Palette.card)
                        .shadow(color: .black.opacity(0.35), radius: 7, y: 3)
                }
            }
            // 让位的距离必须作为参数传下去：SwiftUI 发现下层修饰器的输入没变就会跳过重算，
            // 如果只在里面读模型，其他行就不会动。
            .modifier(DragFollow(active: active, reordering: model.isActive, shift: model.offset(for: id),
                                 drag: active ? model.drag : DragOffset.idle))
            .zIndex(active ? 10 : 0)
    }
}

/// 被拖行紧跟指针，拖动时相邻行平滑让位；松手立即复位。
private struct DragFollow: ViewModifier {
    let active: Bool
    let reordering: Bool
    /// 非跟手状态下的位移：别的行的让位距离，或松手后被拖行落位的距离。
    let shift: CGFloat
    @ObservedObject var drag: DragOffset

    func body(content: Content) -> some View {
        let following = active
        let offset = following ? drag.value : shift
        content
            .offset(y: offset)
            .animation(following || !reordering ? nil : (Motion.reduced ? nil : .spring(response: 0.28, dampingFraction: 0.82)), value: offset)
    }
}
