import AppKit
import Combine
import SwiftUI

/// 一套配色的九个颜色（sRGB 十六进制）。
struct ThemeColors: Equatable {
    let background: UInt32   // 窗口底色
    let card: UInt32         // 卡片、输入框
    let ink: UInt32          // 正文
    let muted: UInt32        // 次要文字
    let accent: UInt32       // 强调色（链接、选中）
    let soft: UInt32         // 强调色的浅底（选中行、标签底）
    let line: UInt32         // 分隔线、描边
    let success: UInt32      // 完成、专注中、开始按钮
    let deadline: UInt32     // 截止、逾期、警示

    /// 相对亮度（WCAG）。
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 255) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /// 两个颜色的对比度（1–21）。
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    /// 强调色填充上的文字：黑白里对比度更高的那个，任何强调色上都至少 4.5 : 1。
    var onAccent: UInt32 {
        Self.contrast(0xFFFFFF, accent) >= Self.contrast(0x000000, accent) ? 0xFFFFFF : 0x000000
    }
}

/// 一套配色：浅色和深色各一组，随系统（或设置里的「外观」）切换。
struct AppTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    let light: ThemeColors
    let dark: ThemeColors

    func colors(dark isDark: Bool) -> ThemeColors { isDark ? dark : light }

    static let all: [AppTheme] = [
        AppTheme(id: "github", name: "默认 · 墨蓝", subtitle: "GitHub 风格的冷静蓝灰",
                 light: ThemeColors(background: 0xF6F8FA, card: 0xFFFFFF, ink: 0x1F2328, muted: 0x59636E, accent: 0x0969DA, soft: 0xDDF4FF, line: 0xD1D9E0, success: 0x1A7F37, deadline: 0xBC4C00),
                 dark: ThemeColors(background: 0x0D1117, card: 0x161B22, ink: 0xF0F6FC, muted: 0x9198A1, accent: 0x4493F8, soft: 0x121D2F, line: 0x3D444D, success: 0x3FB950, deadline: 0xD29922)),
        AppTheme(id: "forest", name: "森林", subtitle: "苔绿与暖灰，护眼",
                 light: ThemeColors(background: 0xF3F7F2, card: 0xFFFFFF, ink: 0x1E2B22, muted: 0x566A5C, accent: 0x2F7D4F, soft: 0xDCEFE2, line: 0xCBD9CE, success: 0x2E7D32, deadline: 0xA8530A),
                 dark: ThemeColors(background: 0x0F1712, card: 0x16221A, ink: 0xE6F2E9, muted: 0x8FA596, accent: 0x5FBF84, soft: 0x17291E, line: 0x2C4034, success: 0x6FCF8A, deadline: 0xE0A84A)),
        AppTheme(id: "sand", name: "暖砂", subtitle: "纸张米色与陶土红",
                 light: ThemeColors(background: 0xF7F1E8, card: 0xFFFBF4, ink: 0x3A2E26, muted: 0x74655A, accent: 0xB5532D, soft: 0xF3E0D0, line: 0xE2D5C3, success: 0x4F7F3A, deadline: 0x9A5A0C),
                 dark: ThemeColors(background: 0x1E1814, card: 0x2A221C, ink: 0xF2E8DC, muted: 0xB3A290, accent: 0xE08A5F, soft: 0x3A2A20, line: 0x4A3D32, success: 0x8DBF6A, deadline: 0xE3B04B)),
        AppTheme(id: "violet", name: "暮紫", subtitle: "夜色里的紫罗兰",
                 light: ThemeColors(background: 0xF5F3FA, card: 0xFFFFFF, ink: 0x2A2540, muted: 0x635D80, accent: 0x6D47D9, soft: 0xE8E1FB, line: 0xD9D3EC, success: 0x2E8B57, deadline: 0xB8400A),
                 dark: ThemeColors(background: 0x15121F, card: 0x1F1B2E, ink: 0xEDE9FA, muted: 0xA39CC0, accent: 0xA78BFA, soft: 0x2A2342, line: 0x3B3458, success: 0x5FD68F, deadline: 0xF0A35A)),
        AppTheme(id: "ocean", name: "海盐", subtitle: "青碧与浅灰蓝",
                 light: ThemeColors(background: 0xF0F7F8, card: 0xFFFFFF, ink: 0x17313A, muted: 0x4F6E78, accent: 0x0E7C86, soft: 0xD6F0F2, line: 0xC5DDE1, success: 0x1F8A5B, deadline: 0xB0520D),
                 dark: ThemeColors(background: 0x0B1A1F, card: 0x112A31, ink: 0xE3F4F6, muted: 0x86A9B1, accent: 0x3CC4CF, soft: 0x123740, line: 0x25454E, success: 0x4FD39A, deadline: 0xE2A04A)),
        AppTheme(id: "sakura", name: "樱粉", subtitle: "柔和的粉与莓红",
                 light: ThemeColors(background: 0xFBF3F5, card: 0xFFFFFF, ink: 0x3B2630, muted: 0x765A66, accent: 0xC2417A, soft: 0xF9E0EA, line: 0xEBD3DB, success: 0x3C8B5E, deadline: 0xA8540E),
                 dark: ThemeColors(background: 0x1F141A, card: 0x2B1B23, ink: 0xF8E9EF, muted: 0xB79AA7, accent: 0xF078A8, soft: 0x3B2230, line: 0x4D3340, success: 0x70CF95, deadline: 0xE8A862)),
        AppTheme(id: "nord", name: "北欧", subtitle: "Nord 冰蓝与雾灰",
                 light: ThemeColors(background: 0xECEFF4, card: 0xFFFFFF, ink: 0x2E3440, muted: 0x566377, accent: 0x4A6F9E, soft: 0xDDE6F2, line: 0xD0D7E2, success: 0x3F7D4B, deadline: 0xA55A14),
                 dark: ThemeColors(background: 0x2E3440, card: 0x3B4252, ink: 0xECEFF4, muted: 0xA9B3C4, accent: 0x88C0D0, soft: 0x3A4A5C, line: 0x4C566A, success: 0xA3BE8C, deadline: 0xEBCB8B)),
        AppTheme(id: "amber", name: "琥珀", subtitle: "复古终端的琥珀黄",
                 light: ThemeColors(background: 0xFBF6E9, card: 0xFFFDF5, ink: 0x2B2A1E, muted: 0x6A664A, accent: 0x8A6A00, soft: 0xF3EAC8, line: 0xE3DABB, success: 0x3F7D1F, deadline: 0xB0480D),
                 dark: ThemeColors(background: 0x14120A, card: 0x1D1A0E, ink: 0xF5E9B8, muted: 0xAFA16B, accent: 0xF5B700, soft: 0x2C2610, line: 0x40391C, success: 0x9BD04F, deadline: 0xFF8A3D)),
        AppTheme(id: "ink", name: "墨红", subtitle: "高对比的黑白加一点红",
                 light: ThemeColors(background: 0xFFFFFF, card: 0xF4F4F5, ink: 0x0A0A0A, muted: 0x595959, accent: 0xD7263D, soft: 0xFDE4E7, line: 0xD9D9D9, success: 0x1B7A3A, deadline: 0xB45309),
                 dark: ThemeColors(background: 0x000000, card: 0x111111, ink: 0xFFFFFF, muted: 0xA3A3A3, accent: 0xFF5470, soft: 0x2A0F15, line: 0x333333, success: 0x4ADE80, deadline: 0xFBBF24)),
    ]

    static let defaultID = "github"
    static let themeKey = "colorTheme"
    static func theme(id: String) -> AppTheme { all.first { $0.id == id } ?? all[0] }

    /// 当前配色。绘制颜色时读取，所以放在不隔离的静态变量里；切换由 `ThemeStore` 负责。
    static var current: AppTheme = theme(id: UserDefaults.standard.string(forKey: themeKey) ?? defaultID)
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" }
    }
    var nsAppearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

/// 当前配色和外观的唯一来源。界面根视图观察它，切换后整个界面立即换色；选择存进偏好。
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    static let themeKey = AppTheme.themeKey
    static let appearanceKey = "appearanceMode"

    @Published private(set) var themeID: String
    @Published private(set) var appearance: AppearanceMode
    private let defaults: UserDefaults
    private let applyAppearance: Bool

    init(defaults: UserDefaults = .standard, applyAppearance: Bool = true) {
        self.defaults = defaults
        self.applyAppearance = applyAppearance
        let saved = defaults.string(forKey: Self.themeKey) ?? AppTheme.defaultID
        themeID = AppTheme.all.contains { $0.id == saved } ? saved : AppTheme.defaultID
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        if defaults === UserDefaults.standard { AppTheme.current = AppTheme.theme(id: themeID) }
        if applyAppearance { NSApp?.appearance = appearance.nsAppearance }
    }

    var theme: AppTheme { AppTheme.theme(id: themeID) }

    func select(_ id: String) {
        guard AppTheme.all.contains(where: { $0.id == id }), id != themeID else { return }
        themeID = id
        defaults.set(id, forKey: Self.themeKey)
        if defaults === UserDefaults.standard { AppTheme.current = AppTheme.theme(id: id) }
    }

    func setAppearance(_ mode: AppearanceMode) {
        guard mode != appearance else { return }
        appearance = mode
        defaults.set(mode.rawValue, forKey: Self.appearanceKey)
        if applyAppearance { NSApp?.appearance = mode.nsAppearance }
    }
}

/// 窗口根视图用它包一层：配色或外观一变就整体重建，所有 `Palette` 颜色重新取值。
/// 只重建里面的子视图，外层视图自己的状态（选中的日期、草稿等）不受影响。
struct ThemedRoot<Content: View>: View {
    @ObservedObject private var themes = ThemeStore.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().id(themes.themeID + "/" + themes.appearance.rawValue)
    }
}

enum Palette {
    static let background = token(\.background)
    static let card = token(\.card)
    static let ink = token(\.ink)
    static let muted = token(\.muted)
    static let accent = token(\.accent)
    static let soft = token(\.soft)
    static let line = token(\.line)
    static let success = token(\.success)
    static let deadline = token(\.deadline)
    /// 强调色填充（选中的标签、主按钮）上的文字。
    static let onAccent = dynamic { $0.onAccent }

    private static func token(_ key: KeyPath<ThemeColors, UInt32>) -> Color { dynamic { $0[keyPath: key] } }

    /// 颜色在每次绘制时按当前配色和外观取值，所以切换配色、深浅色都不用重新创建它们。
    private static func dynamic(_ pick: @escaping (ThemeColors) -> UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = pick(AppTheme.current.colors(dark: isDark))
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}
