import SwiftUI

/// 分段选择：底下一条浅浅的凹槽，选中的那段是一块浮起的小药丸（顶边细高光、轻阴影），切换时药丸滑过去。
/// 系统的分段控件在窗口不是当前窗口时会整体变灰、也换不了配色，这里始终跟随主题。
struct PillSegmentedControl<Value: Hashable>: View {
    struct Segment {
        let value: Value
        let title: String
        var symbol: String?
        /// 标题后面的小数字（比如搜索结果条数）；nil 不显示。
        var count: Int?
    }

    @Binding var selection: Value
    let segments: [Segment]
    /// 每段等宽，撑满给定宽度；否则按内容。
    var fillsWidth = false
    var height: CGFloat = 26
    var fontSize: CGFloat = 12
    /// 放在半透明玻璃上：凹槽更透一些。
    var onGlass = false
    @Namespace private var namespace
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.value) { segment in
                SegmentButton(segment: segment, selected: segment.value == selection, fillsWidth: fillsWidth,
                              height: height - 4, fontSize: fontSize, namespace: namespace) {
                    guard selection != segment.value else { return }
                    withAnimation(Motion.reduced ? nil : .spring(response: 0.3, dampingFraction: 0.82)) { selection = segment.value }
                }
            }
        }
        .padding(2)
        .background {
            let shape = RoundedRectangle(cornerRadius: Metrics.radiusSmall + 2, style: .continuous)
            shape.fill(onGlass ? Palette.background.opacity(scheme == .dark ? 0.32 : 0.4) : Palette.soft.opacity(scheme == .dark ? 0.55 : 0.7))
                // 凹槽：顶边略暗、底边一道细亮线，像压进面板里。
                .overlay(shape.strokeBorder(LinearGradient(colors: [Color.black.opacity(scheme == .dark ? 0.35 : 0.08), Color.white.opacity(scheme == .dark ? 0.06 : 0.6)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: Metrics.hairline))
        }
        .accessibilityElement(children: .contain)
    }

    private struct SegmentButton: View {
        let segment: Segment
        let selected: Bool
        let fillsWidth: Bool
        let height: CGFloat
        let fontSize: CGFloat
        let namespace: Namespace.ID
        let action: () -> Void
        @State private var hovered = false
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    if let symbol = segment.symbol {
                        Image(systemName: symbol).font(.system(size: fontSize - 1, weight: .semibold))
                            .foregroundStyle(selected ? Palette.accent : (hovered ? Palette.ink : Palette.muted))
                    }
                    Text(LocalizedStringKey(segment.title)).lineLimit(1)
                    if let count = segment.count {
                        Text("\(count)").monospacedDigit().font(.system(size: fontSize - 2, weight: .semibold))
                            .foregroundStyle(selected ? Palette.accent : Palette.muted)
                            .padding(.horizontal, 5).frame(minHeight: 15)
                            .background(Capsule().fill((selected ? Palette.accent : Palette.muted).opacity(0.14)))
                    }
                }
                .font(.system(size: fontSize, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected || hovered ? Palette.ink : Palette.muted)
                .padding(.horizontal, 10)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: height)
                .background {
                    if selected {
                        let shape = RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                        shape.fill(Palette.card)
                            .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.07 : 0.55), .clear],
                                                               startPoint: .top, endPoint: .bottom)))
                            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.16 : 0.9), Palette.line.opacity(0.7)],
                                                                       startPoint: .top, endPoint: .bottom), lineWidth: Metrics.hairline))
                            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.14), radius: 2.5, y: 1)
                            .matchedGeometryEffect(id: "pill", in: namespace)
                    } else if hovered {
                        RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).fill(Palette.ink.opacity(0.05))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall))
            }
            .buttonStyle(PressScaleStyle())
            .onHover { hovered = $0 }
            .animation(Motion.reduced ? nil : .easeOut(duration: 0.1), value: hovered)
            .pointerLink()
            .accessibilityLabel(LocalizedStringKey(segment.title))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// 只有按下时轻轻一缩的按钮样式：给自带外观的控件用。
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.reduced ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
