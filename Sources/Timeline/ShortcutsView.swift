import SwiftUI

/// 快捷键一览（主窗口按 ?，或「帮助」菜单）：字母键操作原本只写在菜单标题里，不容易发现。
struct ShortcutsView: View {
    @Environment(\.typography) private var typography
    let close: () -> Void

    private struct Group: Identifiable {
        let title: String
        let rows: [(String, String)]
        var id: String { title }
    }

    private var groups: [Group] {
        [
            Group(title: "全局", rows: HotKeyAction.allCases.map { (HotKeyStore.binding(for: $0).label, $0.title) }),
            Group(title: "清单与日历", rows: [
                ("↑ ↓", "选择上一项 / 下一项"),
                ("← →", "前一天 / 后一天"),
                ("⌘[ ⌘]", "上个月 / 下个月"),
                ("⌘T", "回到今天"),
                ("⌘F", "搜索任务、日志与总结"),
                ("⌘\\", "显示 / 隐藏待办清单"),
                ("⌘J", "当天日志"),
                ("⌘K", "插入链接"),
                ("⌘↩", "保存 / 提交编辑（所有输入框）"),
                ("⌘Z", "撤销上一步"),
            ]),
            Group(title: "选中任务时", rows: [
                ("空格", "完成 / 取消完成"),
                ("↩", "编辑标题"),
                ("D", "截止日期与时间"),
                ("M  ⇧M", "推到明天 / 提前一天"),
                ("T", "标签"),
                ("N", "笔记"),
                ("P", "固定为当前待办"),
                ("F", "开始 / 结束专注"),
                ("X", "放弃（留着记录）"),
                ("⌫", "删除（可撤销）"),
                ("Esc", "取消选择"),
            ]),
            Group(title: "工作板", rows: [
                ("⌘↩", "保存并回到浏览；浏览时进入编辑"),
                ("⌘K", "切换工作板"),
                ("Esc", "取消编辑"),
            ]),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("快捷键").font(.system(size: typography.pt(15), weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(HitAreaButtonStyle(compact: true)).foregroundStyle(Palette.muted)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("关闭")
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) { section(groups[0]); section(groups[3]) }
                VStack(alignment: .leading, spacing: 14) { section(groups[1]); section(groups[2]) }
            }
            Text("全局快捷键可在设置中修改。")
                .font(.system(size: typography.pt(11))).foregroundStyle(Palette.muted)
        }
        .padding(20)
        .frame(width: 600)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
    }

    private func section(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(group.title))
                .font(.system(size: typography.pt(11), weight: .semibold)).foregroundStyle(Palette.muted)
            ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    Text(row.0)
                        .font(.system(size: typography.pt(11), weight: .medium)).monospacedDigit()
                        .padding(.horizontal, 6).frame(minWidth: 44, minHeight: 20)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall - 2, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall - 2, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: Metrics.hairline))
                    Text(LocalizedStringKey(row.1)).font(.system(size: typography.pt(12)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
