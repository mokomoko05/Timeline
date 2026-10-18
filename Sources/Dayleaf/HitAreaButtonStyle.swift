import SwiftUI

struct ItemActionButton: View {
    @Environment(\.typography) private var typography
    let symbol: String
    let title: String
    var destructive = false
    var compact = false
    var showsTitle = false
    /// 开着的开关（比如已固定）：用强调色。
    var active = false
    let action: () -> Void

    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).frame(width: 18, height: 18)
                if showsTitle { Text(LocalizedStringKey(title)) }
            }.font(.system(size: typography.pt(11)))
        }
        .buttonStyle(HitAreaButtonStyle(compact: compact))
        .foregroundStyle(destructive ? Palette.deadline : (active ? Palette.accent : Palette.muted))
        .help(title)
        .accessibilityLabel(title)
    }
}

/// 「能按」的立体反馈：悬停时按钮浮起来（有底色渐变、细边、一点阴影、指针变成小手），按下时压下去（缩小、阴影收掉）。
/// 阴影只在悬停的那一个按钮上才有，不会给每个按钮常驻一层阴影。
struct RaisedSurface: ViewModifier {
    var hovered: Bool
    var pressed: Bool
    var enabled = true
    var radius: CGFloat = 6
    var pressedScale: CGFloat = 0.94
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let lifted = hovered && enabled && !pressed
        let shape = RoundedRectangle(cornerRadius: radius)
        content
            .background {
                if (hovered || pressed) && enabled {
                    shape.fill(LinearGradient(colors: [Palette.soft, Palette.soft.opacity(pressed ? 1 : 0.7)], startPoint: .top, endPoint: .bottom))
                        // 顶边一道高光，底边略暗：像一个有厚度的小按键。
                        .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(pressed ? 0.04 : (dark ? 0.34 : 0.22)), Palette.line.opacity(0.9)],
                                                                   startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                }
            }
            .shadow(color: .black.opacity(lifted ? (dark ? 0.55 : 0.22) : 0), radius: lifted ? 3 : 0, x: 0, y: lifted ? 1.5 : 0)
            .scaleEffect(pressed && enabled ? pressedScale : 1)
            .offset(y: lifted ? -0.5 : 0)
            .animation(Motion.reduced ? nil : .easeOut(duration: 0.09), value: hovered)
            .animation(Motion.reduced ? nil : .easeOut(duration: 0.09), value: pressed)
            .pointerLink(enabled)
    }
}

extension View {
    /// 悬停时指针变成小手（macOS 15 以上）。
    @ViewBuilder
    func pointerLink(_ enabled: Bool = true) -> some View {
        if #available(macOS 15.0, *), enabled { self.pointerStyle(.link) } else { self }
    }

    /// 给任意可点击的视图加上和按钮一致的悬停浮起效果。
    func raisedOnHover(radius: CGFloat = 6, enabled: Bool = true) -> some View { modifier(RaisedHover(radius: radius, enabled: enabled)) }
}

struct RaisedHover: ViewModifier {
    var radius: CGFloat
    var enabled: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content.modifier(RaisedSurface(hovered: hovered, pressed: false, enabled: enabled, radius: radius)).onHover { hovered = $0 }
    }
}

struct HitAreaButtonStyle: ButtonStyle {
    var compact = false
    var pressedScale: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, compact: compact, pressedScale: pressedScale)
    }

    private struct Surface: View {
        let configuration: ButtonStyle.Configuration
        let compact: Bool
        let pressedScale: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, compact ? 3 : 6)
                .padding(.vertical, compact ? 2 : 4)
                .frame(minWidth: compact ? 22 : 30, minHeight: compact ? 22 : 30)
                .modifier(RaisedSurface(hovered: hovered, pressed: configuration.isPressed, enabled: enabled, pressedScale: pressedScale))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovered = $0 }
        }
    }
}
