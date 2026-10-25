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
    /// 指针已经越过这一日期分组的上下边界：该切换成「拖到别的日期」。
    var escaped: (CGFloat) -> Bool = { _ in false }
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
    nonisolated static let spacing: CGFloat = 6

    /// 各行在清单内容坐标里的位置（不随滚动变化），由布局回传；不需要触发刷新。
    var frames: [UUID: CGRect] = [:]
    /// 给定一个任务，返回它所在分组里全部任务的 id（按显示顺序）。
    var groupProvider: (UUID) -> [UUID] = { _ in [] }
    /// 点把手会选中任务，选中又会触发「滚动到选中项」；排序拖动开始时这个滚动会让清单漂移，所以点把手这一次不滚动。
    var suppressScroll = false
    /// 松手后提交新的顺序。
    var commit: ([UUID]) -> Void = { _ in }

    @Published private(set) var activeID: UUID?
    /// 松手后正在滑进新位置的那一行。
    @Published private(set) var settlingID: UUID?
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
        settlingID = nil
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

    /// 指针离开本组的上下边界超过半行：用户要把它拖到别的日期，而不是在组内排序。
    func hasEscaped(_ translation: CGFloat) -> Bool {
        guard activeID != nil, groupFrames.indices.contains(activeIndex), let first = groupFrames.first, let last = groupFrames.last else { return false }
        let row = groupFrames[activeIndex]
        let margin = max(18, row.height * 0.6)
        return row.minY + translation < first.minY - margin || row.maxY + translation > last.maxY + margin
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

    /// 松手立即提交顺序；被拖的行从松手处滑进新位置。
    func finish() {
        guard let id = activeID else { return }
        // 提交后这一行已排在新位置，先补上它和松手处的差距，再把差距动画归零：只有这一行在动，其他行和数据都已就位。
        let residual = dragOffset - ReorderMath.slotOffset(frames: groupFrames, active: activeIndex, target: target)
        let settles = !Motion.reduced && abs(residual) > 0.5
        complete(order: ReorderMath.moved(group, from: activeIndex, to: target), changed: target != activeIndex,
                 settling: settles ? (id, residual) : nil)
        guard settles else { return }
        // 等补偿后的位置先画出一帧再归零；同一轮里改回去会和提交合并，动画从错的位置开始。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self, self.settlingID == id else { return }
            self.drag.value = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration) { [weak self] in
                guard let self, self.settlingID == id else { return }
                withAnimation(Motion.quick) { self.settlingID = nil }
            }
        }
    }

    nonisolated static let settleDuration = 0.24
    static var settleAnimation: Animation { .spring(response: settleDuration, dampingFraction: 0.86) }

    func cancel() {
        guard activeID != nil else { return }
        complete(order: group, changed: false, settling: nil)
    }

    private func complete(order: [UUID], changed: Bool, settling: (id: UUID, offset: CGFloat)?) {
        // 顺序和位移在同一刻一起复位，行已经在新位置上，所以看不到跳动。
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if changed { commit(order) }
            activeID = nil
            settlingID = settling?.id
            dragOffset = 0
            drag.value = settling?.offset ?? 0
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
        let settling = model.settlingID == id
        content
            .background {
                // 阴影画在行的背后，而不是给整行（里面有原生文本控件）加 .shadow，否则每帧都要把整行离屏渲染一遍。
                if active || settling {
                    // 被拖的行浮起：卡片底色加一道细边和固定的轻阴影，合成成一张图层跟手移动。
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.card)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.accent.opacity(0.35), lineWidth: Metrics.hairline))
                        .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
                        .drawingGroup()
                }
            }
            // 让位的距离必须作为参数传下去：SwiftUI 发现下层修饰器的输入没变就会跳过重算，
            // 如果只在里面读模型，其他行就不会动。
            .modifier(DragFollow(active: active, settling: settling, reordering: model.isActive, shift: model.offset(for: id),
                                 drag: active || settling ? model.drag : DragOffset.idle))
            .zIndex(active || settling ? 10 : 0)
    }
}

/// 被拖行紧跟指针，拖动时相邻行平滑让位；松手后被拖行滑进新位置。
private struct DragFollow: ViewModifier {
    let active: Bool
    let settling: Bool
    let reordering: Bool
    /// 非跟手状态下的位移：别的行的让位距离，或松手后被拖行落位的距离。
    let shift: CGFloat
    @ObservedObject var drag: DragOffset

    func body(content: Content) -> some View {
        let offset = active || settling ? drag.value : shift
        content
            .offset(y: offset)
            .animation(animation, value: offset)
    }

    private var animation: Animation? {
        if Motion.reduced || active { return nil }
        if settling { return TaskReorderModel.settleAnimation }
        return reordering ? .spring(response: 0.28, dampingFraction: 0.82) : nil
    }
}
