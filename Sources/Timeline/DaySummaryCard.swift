import SwiftUI
import TimelineCore

/// 每日总结：日记里这一天时间轴末端的卡片。点正文就地编辑（和日志同一个编辑器）；还没写时是空卡片，点一下从头写。
struct DaySummaryCard: View {
    @ObservedObject var store: JournalStore
    let date: Date
    var hasPrevious = true
    var highlighted = false
    @Environment(\.typography) private var typography
    @Environment(\.colorScheme) private var colorScheme

    private var id: UUID { InlineMarkdownEditor.summaryID(for: date) }
    private var beadY: CGFloat { typography.pt(20) }

    var body: some View {
        let summary = store.entry(for: date).summary
        let editable = !store.isReadOnly
        VStack(alignment: .leading, spacing: 6) {
            Text("每日总结").font(.system(size: typography.pt(11), weight: .semibold)).foregroundStyle(Palette.muted)
            EditableLogText(id: id, editable: editable, begin: { point, _ in begin(at: point) }) { editAt in
                if summary.isEmpty {
                    Text(editable ? "写点今天的总结…" : "还没有总结")
                        .font(.system(size: typography.pt(13))).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TaskLinkText(source: summary, completed: false, color: Palette.ink, fontSize: 13,
                                 edit: { begin(at: nil) }, open: SafariLinks.open, maxLines: 0,
                                 markdown: true, compactLines: true, editAt: editAt, foldID: InlineMarkdownEditor.foldID(id))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? Palette.accent.opacity(0.12) : Palette.soft.opacity(0.55), in: RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous).strokeBorder(Palette.line.opacity(0.7)) }
        .contentShape(Rectangle())
        // 空卡片整张都能点；写了内容后点正文（链接、折叠按钮都由正文自己处理）。
        .onTapGesture { if summary.isEmpty, editable, !InlineMarkdownEditor.shared.isEditing(id) { begin(at: nil) } }
        .padding(.leading, NoteThread.gutter + 10)
        .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 6)
        .overlay(alignment: .topLeading) { rail.padding(.leading, 8) }
        .accessibilityElement(children: .contain).accessibilityLabel("每日总结")
    }

    private func begin(at point: CGPoint?) {
        InlineMarkdownEditor.shared.beginSummary(on: date, store: store, at: point, fontSize: typography.pt(13),
                                                 lineSpacing: typography.lineSpacing, dark: colorScheme == .dark)
    }

    private var rail: some View {
        ZStack(alignment: .topLeading) {
            if hasPrevious {
                Path { path in
                    path.move(to: CGPoint(x: NoteThread.axisX, y: 0))
                    path.addLine(to: CGPoint(x: NoteThread.axisX, y: beadY))
                }.stroke(Palette.line.opacity(0.7), lineWidth: 1)
            }
            Image(systemName: "sun.max").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.deadline)
                .frame(width: 13, height: 13)
                .background(Palette.background, in: Circle())
                .overlay(Circle().strokeBorder(Palette.deadline.opacity(0.8), lineWidth: 1.1))
                .position(x: NoteThread.axisX, y: beadY)
        }
        .frame(width: NoteThread.gutter, height: beadY + 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
