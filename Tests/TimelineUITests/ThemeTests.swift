import AppKit
import SwiftUI
import XCTest
@testable import Timeline

@MainActor
final class ThemeTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private func defaults() -> UserDefaults {
        let suite = "theme-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist"))
        }
        return defaults
    }

    func testThereAreSeveralDistinctThemesWithUniqueIDs() {
        XCTAssertGreaterThanOrEqual(AppTheme.all.count, 8)
        XCTAssertEqual(Set(AppTheme.all.map(\.id)).count, AppTheme.all.count, "id 唯一")
        XCTAssertEqual(Set(AppTheme.all.map(\.name)).count, AppTheme.all.count, "名字唯一")
        XCTAssertEqual(AppTheme.all.first?.id, AppTheme.defaultID)
        for theme in AppTheme.all {
            XCTAssertNotEqual(theme.light, theme.dark, "\(theme.name) 的浅色和深色不一样")
            XCTAssertGreaterThan(ThemeColors.luminance(theme.light.background), ThemeColors.luminance(theme.dark.background), "\(theme.name)：浅色版比深色版亮")
        }
        let accents = Set(AppTheme.all.map { $0.light.accent })
        XCTAssertEqual(accents.count, AppTheme.all.count, "每套的强调色各不相同")
    }

    func testDefaultThemeKeepsTheOriginalColors() {
        let github = AppTheme.theme(id: "github")
        XCTAssertEqual(github.light.background, 0xF6F8FA)
        XCTAssertEqual(github.light.accent, 0x0969DA)
        XCTAssertEqual(github.dark.background, 0x0D1117)
        XCTAssertEqual(github.dark.accent, 0x4493F8)
        XCTAssertEqual(github.dark.success, 0x3FB950)
        XCTAssertEqual(AppTheme.theme(id: "不存在").id, AppTheme.defaultID, "未知的 id 退回默认")
    }

    /// 每套配色的浅色、深色版本都要让文字、强调色、状态色在底色和卡片上清晰可读（WCAG 对比度）。
    func testEveryThemeIsReadableInLightAndDark() {
        for theme in AppTheme.all {
            for (mode, c) in [("浅色", theme.light), ("深色", theme.dark)] {
                func atLeast(_ ratio: Double, _ a: UInt32, _ b: UInt32, _ what: String) {
                    let value = ThemeColors.contrast(a, b)
                    XCTAssertGreaterThanOrEqual(value, ratio, "\(theme.name)·\(mode)：\(what) 对比度 \(String(format: "%.2f", value)) 低于 \(ratio)")
                }
                atLeast(7, c.ink, c.background, "正文/底色")
                atLeast(7, c.ink, c.card, "正文/卡片")
                atLeast(7, c.ink, c.soft, "正文/选中底")
                atLeast(4.2, c.muted, c.background, "次要文字/底色")
                atLeast(4.2, c.muted, c.card, "次要文字/卡片")
                atLeast(3.5, c.accent, c.background, "强调色/底色")
                atLeast(3.5, c.accent, c.card, "强调色/卡片")
                atLeast(3.5, c.accent, c.soft, "强调色/选中底")
                atLeast(3, c.success, c.background, "完成色/底色")
                atLeast(3, c.success, c.card, "完成色/卡片")
                atLeast(3, c.deadline, c.background, "警示色/底色")
                atLeast(3, c.deadline, c.card, "警示色/卡片")
                atLeast(1.15, c.line, c.background, "分隔线/底色")
                atLeast(4.5, c.onAccent, c.accent, "强调色填充上的文字")
                XCTAssertNotEqual(c.background, c.card, "\(theme.name)·\(mode)：卡片和底色要能分开")
            }
        }
    }

    func testOnAccentPicksTheReadableOfBlackAndWhite() {
        XCTAssertEqual(ThemeColors.contrast(0xFFFFFF, 0x000000), 21, accuracy: 0.01)
        let dark = AppTheme.theme(id: "ink").light      // 红色强调色：白字
        let bright = AppTheme.theme(id: "amber").dark   // 亮琥珀：黑字
        XCTAssertEqual(dark.onAccent, 0xFFFFFF)
        XCTAssertEqual(bright.onAccent, 0x000000)
    }

    func testPaletteColorsFollowTheCurrentThemeAndAppearance() throws {
        let original = AppTheme.current
        defer { AppTheme.current = original }
        func resolved(_ color: Color, dark: Bool) -> UInt32 {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            var result: UInt32 = 0
            appearance.performAsCurrentDrawingAppearance {
                let ns = NSColor(color).usingColorSpace(.sRGB)!
                result = (UInt32((ns.redComponent * 255).rounded()) << 16) | (UInt32((ns.greenComponent * 255).rounded()) << 8) | UInt32((ns.blueComponent * 255).rounded())
            }
            return result
        }
        for theme in AppTheme.all {
            AppTheme.current = theme
            XCTAssertEqual(resolved(Palette.background, dark: false), theme.light.background, "\(theme.name) 浅色底")
            XCTAssertEqual(resolved(Palette.background, dark: true), theme.dark.background, "\(theme.name) 深色底")
            XCTAssertEqual(resolved(Palette.accent, dark: true), theme.dark.accent)
            XCTAssertEqual(resolved(Palette.success, dark: false), theme.light.success)
        }
    }

    func testStorePersistsSelectionAndAppearanceAndRejectsUnknownIDs() {
        let defaults = defaults()
        let store = ThemeStore(defaults: defaults, applyAppearance: false)
        XCTAssertEqual(store.themeID, AppTheme.defaultID)
        XCTAssertEqual(store.appearance, .system)
        store.select("forest")
        store.select("没有这个主题")
        XCTAssertEqual(store.themeID, "forest")
        store.setAppearance(.dark)
        let reopened = ThemeStore(defaults: defaults, applyAppearance: false)
        XCTAssertEqual(reopened.themeID, "forest", "重启后还是上次选的配色")
        XCTAssertEqual(reopened.appearance, .dark)
        defaults.set("损坏的值", forKey: ThemeStore.themeKey)
        XCTAssertEqual(ThemeStore(defaults: defaults, applyAppearance: false).themeID, AppTheme.defaultID, "偏好里的值坏了就用默认")
        XCTAssertNil(AppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)
    }

    func testThemePickerAndRootsRenderForEveryTheme() {
        let defaults = defaults()
        let store = ThemeStore(defaults: defaults, applyAppearance: false)
        let host = NSHostingView(rootView: ThemePicker(themes: store).frame(width: 460))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        Self.keepAlive += [window, host]
        XCTAssertGreaterThan(host.fittingSize.height, 150, "九张配色卡片都排得下")
    }
}
