import SwiftUI

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

/// 圆角、间距、描边的统一取值：同类元素用同一档，界面才显得整齐。
enum Metrics {
    /// 行内小控件（标签、按钮底）。
    static let radiusSmall: CGFloat = 6
    /// 卡片、输入框、日历格。
    static let radiusMedium: CGFloat = 8
    /// 浮动面板（快速记录、专注、工作板）。
    static let radiusPanel: CGFloat = 14
    static let hairline: CGFloat = 0.75
}

extension View {
    /// 浮动面板的外观：卡片底色、大圆角、细描边；阴影由窗口提供。
    func floatingPanelSurface() -> some View {
        modifier(FloatingPanelSurface())
    }
}

/// 浮动面板：卡片色加一点自上而下的光，顶边一道细高光，像一块有厚度的面板。
private struct FloatingPanelSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
        content
            .background {
                shape.fill(Palette.card)
                    .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.035 : 0.5), .clear],
                                                       startPoint: .top, endPoint: .center)))
            }
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.14 : 0.9), Palette.line.opacity(0.8)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: Metrics.hairline)
                .allowsHitTesting(false))
    }
}

/// 窗口底色：主题底色上从左上角透出一点强调色的光，深浅外观都很克制，只让大面积底色不那么平。
struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        AmbientBackdropLayer(dark: scheme == .dark)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// 用图层画背景：纯色和径向渐变都由系统合成，不像 SwiftUI 渐变那样在应用里常驻一张整窗大小的位图（每个窗口约 19 MB）。
private struct AmbientBackdropLayer: NSViewRepresentable {
    let dark: Bool

    func makeNSView(context: Context) -> AmbientBackdropView { AmbientBackdropView() }
    func updateNSView(_ view: AmbientBackdropView, context: Context) { view.dark = dark }
}

final class AmbientBackdropView: NSView {
    static let radius: CGFloat = 720
    let gradient = CAGradientLayer()
    var dark = false { didSet { if dark != oldValue { refreshColors() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.type = .radial
        layer?.addSublayer(gradient)
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        // 圆心在左上角（图层坐标原点在左下），半径按单位坐标换算。
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: Self.radius / max(bounds.width, 1), y: 1 - Self.radius / max(bounds.height, 1))
        CATransaction.commit()
    }

    private func refreshColors() {
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let accent = NativePalette.accent.usingColorSpace(.sRGB) ?? NativePalette.accent
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.backgroundColor = NativePalette.background.cgColor
            // 渐变终点用同色透明，避免和黑色透明插值出灰边。
            gradient.colors = [accent.withAlphaComponent(dark ? 0.07 : 0.045).cgColor, accent.withAlphaComponent(0).cgColor]
            CATransaction.commit()
        }
    }
}

/// 细进度条：系统 ProgressView 在窗口不是当前窗口时会变灰，这里始终用主题色。
struct ThemedProgressBar: View {
    let fraction: Double
    var tint: Color = Palette.accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line.opacity(0.6))
                Capsule().fill(tint)
                    .frame(width: fraction > 0 ? max(6, proxy.size.width * min(1, fraction)) : 0)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((min(1, max(0, fraction)) * 100).rounded()))%"))
    }
}

extension View {
    /// 输入框外观：卡片底色、细边，聚焦时边框换成强调色。各处输入框共用，看起来是同一种控件。
    func inputFieldSurface(focused: Bool, fill: Color = Palette.card) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous)
                .strokeBorder(focused ? Palette.accent.opacity(0.7) : Palette.line.opacity(0.7), lineWidth: focused ? 1.25 : Metrics.hairline)
                .allowsHitTesting(false))
    }
}

extension View {
    /// 半透明玻璃：透出后面的桌面，顶边一道细高光，阴影由窗口提供。
    func glassPanelSurface(radius: CGFloat = Metrics.radiusPanel, clear: Bool = false) -> some View {
        modifier(GlassPanelSurface(radius: radius, clear: clear))
    }
}

private struct GlassPanelSurface: ViewModifier {
    let radius: CGFloat
    /// 近乎全透明：几乎不模糊、不着色，只留一道细边勾出轮廓；文字加一层很淡的阴影，放在任何桌面上都看得清。
    var clear = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if clear {
            content
                .shadow(color: (scheme == .dark ? Color.black : Color.white).opacity(scheme == .dark ? 0.75 : 0.6), radius: 1.6, y: 0.5)
                .background {
                    shape.fill(Palette.background.opacity(scheme == .dark ? 0.08 : 0.1))
                        .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.05 : 0.18), .clear],
                                                           startPoint: .top, endPoint: .center)))
                }
                .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.28 : 0.85), Palette.line.opacity(0.35)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: Metrics.hairline)
                    .allowsHitTesting(false))
                .clipShape(shape)
        } else {
            standard(content, shape: shape)
        }
    }

    private func standard(_ content: Content, shape: RoundedRectangle) -> some View {
        content
            .background {
                // 透明度更高：只留一层很薄的底色，桌面的颜色能透上来；文字靠材质的模糊保持可读。
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(Palette.card.opacity(scheme == .dark ? 0.12 : 0.18)))
                    .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.08 : 0.28), .clear],
                                                       startPoint: .top, endPoint: .center)))
            }
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.22 : 0.9), Palette.line.opacity(0.5)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: Metrics.hairline)
                .allowsHitTesting(false))
            .clipShape(shape)
    }
}

