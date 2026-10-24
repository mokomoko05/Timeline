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
    let danger: UInt32       // 紧急、删除、失败
    let attention: UInt32    // 高优先级、提醒
    let done: UInt32         // 复盘、已归档（紫）
    let note: UInt32         // 笔记、次要高亮（青）

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
                 light: ThemeColors(background: 0xF6F8FA, card: 0xFFFFFF, ink: 0x1F2328, muted: 0x59636E, accent: 0x0969DA, soft: 0xDDF4FF, line: 0xD1D9E0, success: 0x1A7F37, deadline: 0xBC4C00,
                                    danger: 0xCF222E, attention: 0x9A6700, done: 0x8250DF, note: 0x1B7C83),
                 dark: ThemeColors(background: 0x0D1117, card: 0x161B22, ink: 0xF0F6FC, muted: 0x9198A1, accent: 0x4493F8, soft: 0x121D2F, line: 0x3D444D, success: 0x3FB950, deadline: 0xD29922,
                                   danger: 0xF85149, attention: 0xDB6D28, done: 0xAB7DF8, note: 0x39C5CF)),
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
        if saved != themeID { defaults.set(themeID, forKey: Self.themeKey) }
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
    static let danger = token(\.danger)
    static let attention = token(\.attention)
    static let done = token(\.done)
    static let note = token(\.note)
    /// 强调色填充（选中的标签、主按钮）上的文字。
    static let onAccent = dynamic { $0.onAccent }

    private static func token(_ key: KeyPath<ThemeColors, UInt32>) -> Color { Color(nsColor: NativePalette.color(key)) }
    private static func dynamic(_ pick: @escaping (ThemeColors) -> UInt32) -> Color { Color(nsColor: NativePalette.dynamic(pick)) }
}

/// 同一套配色的 AppKit 版本：原生文本视图、分隔条、终端边框用它，跟随外观和配色。
enum NativePalette {
    static let accent = color(\.accent)
    static let line = color(\.line)
    static let muted = color(\.muted)
    static let ink = color(\.ink)
    static let background = color(\.background)
    static let card = color(\.card)
    static let soft = color(\.soft)

    static func color(_ key: KeyPath<ThemeColors, UInt32>) -> NSColor { dynamic { $0[keyPath: key] } }

    /// 颜色在每次绘制时按当前配色和外观取值，所以切换配色、深浅色都不用重新创建它们。
    static func dynamic(_ pick: @escaping (ThemeColors) -> UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = pick(AppTheme.current.colors(dark: isDark))
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        }
    }
}
