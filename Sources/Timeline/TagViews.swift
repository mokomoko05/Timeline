import SwiftUI
import TimelineCore

/// 自动换行的横向排列：标签一行放不下就折到下一行。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (positions, CGSize(width: widest, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(subviews, width: bounds.width)
        for (view, point) in zip(subviews, laid.positions) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// 圆角矩形标签：`highlighted` 表示选中。
struct TagChip: View {
    @Environment(\.typography) private var typography
    let name: String
    var highlighted = false
    /// 批量时只有一部分日志带这个标签：描边但不填充。
    var partial = false
    var size: CGFloat = 12

    var body: some View {
        Text("#" + name)
            .font(.system(size: typography.pt(size), weight: highlighted ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(highlighted ? Palette.onAccent : (partial ? Palette.accent : Palette.ink))
            .background(highlighted ? Palette.accent : Palette.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(highlighted ? Color.clear : (partial ? Palette.accent : Palette.line), lineWidth: partial ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// 待办行里的一排标签（点一下打开这个标签名下的笔记）。
struct TaskTagLine: View {
    @Environment(\.typography) private var typography
    let tags: [String]
    var fontSize: CGFloat = 10
    /// 标签挂在一条日志上：点开笔记本后滚到这一条。
    var log: UUID?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    // 笔记窗口已经建好就直接在里面打开（主窗口可能收起着，界面已经释放）；否则交给主窗口去建。
                    if NotesWindowController.shared.window != nil { NotesWindowController.shared.openTag(tag, log: log) }
                    else { NotificationCenter.default.post(name: .timelineOpenTag, object: tag, userInfo: log.map { ["log": $0] }) }
                } label: {
                    Text("#" + tag).font(.system(size: typography.pt(fontSize))).lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Palette.soft, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.accent)
                .help(AppLocalizedFormat("查看 #%@ 名下的笔记", tag))
            }
        }
    }
}

/// 给一个待办选标签：已有的标签是圆角矩形，选中的高亮，点一下切换；也可以输入新标签。
struct TagPickerView: View {
    @ObservedObject var store: JournalStore
    let task: Todo
    var body: some View {
        TagSelectionPopover(store: store, tags: Binding(
            get: { store.locate(task.id)?.task.tags ?? task.tags },
            set: { store.setTags(task.id, $0) }), title: String(TaskText.rendered(task.title).characters))
    }
}
