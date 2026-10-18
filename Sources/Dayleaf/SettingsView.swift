import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var loginItem: LoginItem
    @ObservedObject private var themes = ThemeStore.shared
    @ObservedObject private var languages = LanguageStore.shared
    let failedHotKeys: () -> Set<HotKeyAction>?
    @AppStorage(Prefs.hideCompleted) private var hideCompleted = false
    @AppStorage(Prefs.clickExpands) private var clickExpands = true
    @AppStorage(Prefs.weekStartsSunday) private var weekStartsSunday = false
    @AppStorage(Prefs.uiScale) private var uiScale = 1.0
    @AppStorage(Prefs.lineSpacing) private var lineSpacing = 2.0
    @AppStorage(Prefs.globalHotKey) private var globalHotKey = true
    @AppStorage(Prefs.terminalLayout) private var terminalLayout = TerminalLayout.threePanes.rawValue
    @AppStorage(Prefs.focusMinLogMinutes) private var focusMinLogMinutes = Prefs.defaultFocusMinLogMinutes
    @AppStorage(Prefs.focusPanelStyle) private var focusPanelStyle = FocusPanelStyle.card.rawValue
    @AppStorage(Prefs.focusPanelHidden) private var focusPanelHidden = false
    @AppStorage(AutoHideOnResign.prefKey) private var autoHideOnResign = true

    var body: some View {
        Form {
            Section("日历与清单") {
                Picker("每周从", selection: $weekStartsSunday) {
                    Text("周一").tag(false)
                    Text("周日").tag(true)
                }.pickerStyle(.segmented)
                Toggle("单击日期时自动展开待办清单", isOn: $clickExpands)
                Text("关闭后，单击日期只选中它；双击或点标题栏的日期按钮再展开清单，日历不会随点击改变布局。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("隐藏已完成事项", isOn: $hideCompleted)
            }
            Section("配色") {
                ThemePicker(themes: themes)
            }
            Section("文字显示") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("整体字号")
                        Spacer()
                        Text("\(Int((uiScale * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                    }
                    Slider(value: $uiScale, in: 0.80...1.50, step: 0.01)
                    HStack {
                        Text("80%").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("150%").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("行间距")
                        Spacer()
                        Text("\(String(format: "%.1f", lineSpacing)) pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                    }
                    Slider(value: $lineSpacing, in: 0...10, step: 0.5)
                    HStack {
                        Text("紧凑").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("宽松").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("字号和行间距会应用到任务、笔记、日记和搜索结果；修改后立即生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("专注计时") {
                Toggle("隐藏专注工作台", isOn: $focusPanelHidden)
                Text("快捷键 \(HotKeyStore.binding(for: .focusPanel).label) 打开任务选择器。选择任务后，右下角会常驻显示本轮倒计时、目标和笔记输入；时长默认为 25 分钟，也可以在开始前自定义。")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $focusMinLogMinutes, in: 0...120) {
                    Text(focusMinLogMinutes == 0 ? "所有专注都记入日志" : "专注不足 \(focusMinLogMinutes) 分钟不记日志")
                }
                Text("专注期间可以自由切换网页、终端和笔记，不会因为离开任务链接而自动停止。手滑点了播放键、很快就结束的专注，不会在日志里留下记录；用过的时间仍然累加到任务上。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("通用") {
                Picker("界面语言", selection: Binding(get: { languages.language }, set: { languages.set($0) })) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                Toggle("登录时自动启动", isOn: Binding(get: { loginItem.enabled }, set: loginItem.setEnabled))
                Toggle("切到别的应用时自动收起窗口", isOn: $autoHideOnResign)
                Text("主窗口、笔记、日志、终端、设置在 Scheduler 失去前台时立刻收起（里面的内容、草稿、终端里的程序都保留）；快速日志和专注计时窗口不受影响，失焦也留在屏幕上。用全局快捷键或点 Dock 图标再唤起。在 Scheduler 自己的窗口之间切换不算离开。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("新建终端的布局", selection: $terminalLayout) {
                    Text("三窗格：左边上下两格，右边一栏").tag(TerminalLayout.threePanes.rawValue)
                    Text("单窗格").tag(TerminalLayout.single.rawValue)
                }
                Toggle("启用全局快捷键", isOn: $globalHotKey)
                if globalHotKey {
                    ForEach(HotKeyAction.allCases) { HotKeyRecorder(action: $0) }
                    if let failed = failedHotKeys(), !failed.isEmpty {
                        Text("「\(failed.map(\.title).joined(separator: "」「"))」的组合已被其他应用占用，请换一个。")
                            .font(.caption).foregroundStyle(Palette.deadline)
                    }
                    Text("点组合框后直接按下想要的键（需要至少一个 ⌃ ⌥ ⌘）。在 Scheduler 或终端里再按一次就隐藏并回到刚才的应用；日志窗口里再按同一个键关闭，Tab 切换待办 / 日志（待办窗口按 Esc 关闭）；笔记窗口开着时再按一次关闭。菜单栏的叶子图标也能打开快速添加待办。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 830)
    }
}

@MainActor
final class SettingsWindowController {
    private(set) var window: NSWindow?
    private let loginItem: LoginItem
    private let failedHotKeys: () -> Set<HotKeyAction>?
    private var languageObserver: NSObjectProtocol?

    init(loginItem: LoginItem, failedHotKeys: @escaping () -> Set<HotKeyAction>?) {
        self.loginItem = loginItem
        self.failedHotKeys = failedHotKeys
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.window?.title = AppLocalized("设置") }
        }
    }

    deinit { if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 830),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = AppLocalized("设置")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LocalizedRoot {
                SettingsView(loginItem: self.loginItem, failedHotKeys: self.failedHotKeys)
            })
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 专注计时窗口的样式选择：每种样式画一个小样，点一下切换，立即生效。
struct FocusStylePicker: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("计时窗口样式").font(.system(size: 12, weight: .medium))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(FocusPanelStyle.allCases) { style in
                    let chosen = selection == style.rawValue
                    Button { selection = style.rawValue } label: {
                        VStack(spacing: 6) {
                            FocusStyleSample(style: style).frame(height: 34)
                            Text(style.title).font(.system(size: 11, weight: chosen ? .semibold : .regular))
                        }
                        .padding(.vertical, 8).frame(maxWidth: .infinity)
                        .background(chosen ? Palette.soft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(chosen ? Palette.accent : Palette.line, lineWidth: chosen ? 1.5 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("样式 \(style.title)：\(style.detail)")
                    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                }
            }
            Text((FocusPanelStyle(rawValue: selection) ?? .card).detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FocusStyleSample: View {
    let style: FocusPanelStyle

    var body: some View {
        let time = Text("12:34").font(.system(size: 10, weight: .medium, design: .monospaced))
        ZStack {
            switch style {
            case .card:
                HStack(spacing: 3) { time; Text("任务").font(.system(size: 8)); Image(systemName: "stop.circle.fill").font(.system(size: 9)).foregroundStyle(.red) }
                    .padding(.horizontal, 6).frame(height: 24).background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
            case .pill:
                HStack(spacing: 3) { time; Image(systemName: "stop.circle.fill").font(.system(size: 9)).foregroundStyle(.red) }
                    .padding(.horizontal, 7).frame(height: 20).background(Palette.card, in: Capsule())
            case .digits:
                time.opacity(0.45)
            case .dot:
                Circle().fill(Palette.success).frame(width: 7, height: 7).opacity(0.75)
            case .menuBar:
                HStack(spacing: 2) { Image(systemName: "timer").font(.system(size: 8)); time }
                    .padding(.horizontal, 5).frame(height: 14).background(Palette.line.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .foregroundStyle(Palette.ink).frame(maxWidth: .infinity)
    }
}
