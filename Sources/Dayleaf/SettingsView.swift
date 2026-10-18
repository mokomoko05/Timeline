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
    @AppStorage(Prefs.globalHotKey) private var globalHotKey = true
    @AppStorage(Prefs.terminalLayout) private var terminalLayout = TerminalLayout.threePanes.rawValue
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
                Toggle("隐藏已完成事项", isOn: $hideCompleted)
            }
            Section("配色") {
                ThemePicker(themes: themes)
            }
            Section("文字显示") {
                TypographySettings()
            }
            Section("专注计时") {
                Toggle("隐藏专注工作台", isOn: $focusPanelHidden)
                FocusMinutesSetting(title: "默认专注时长", key: Prefs.focusDefaultMinutes,
                                    fallback: Prefs.defaultFocusMinutes, minimum: 1)
                FocusMinutesSetting(title: "日志记录门槛", key: Prefs.focusMinLogMinutes,
                                    fallback: Prefs.defaultFocusMinLogMinutes, minimum: 0)
                Text("低于门槛不记日志，0 表示全部记录。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("暂停不计时，切换应用不影响专注。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("通用") {
                Picker("界面语言", selection: Binding(get: { languages.language }, set: { languages.set($0) })) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.title)).tag(language)
                    }
                }
                Toggle("登录时自动启动", isOn: Binding(get: { loginItem.enabled }, set: loginItem.setEnabled))
                Toggle("切到别的应用时自动收起窗口", isOn: $autoHideOnResign)
                Text("快速记录与专注面板保持显示。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("新建终端的布局", selection: $terminalLayout) {
                    Text("三窗格：左边上下两格，右边一栏").tag(TerminalLayout.threePanes.rawValue)
                    Text("单窗格").tag(TerminalLayout.single.rawValue)
                }
                Toggle("启用全局快捷键", isOn: $globalHotKey)
                if globalHotKey {
                    ForEach(HotKeyAction.allCases) { HotKeyRecorder(action: $0) }
                    if let failed = failedHotKeys(), !failed.isEmpty {
                        Text("「\(failed.map { AppLocalized($0.title) }.joined(separator: ", "))」的组合已被其他应用占用，请换一个。")
                            .font(.caption).foregroundStyle(Palette.deadline)
                    }
                    Text("点击录入快捷键，需包含 ⌃、⌥ 或 ⌘。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 830)
    }
}

struct FocusMinutesSetting: View {
    let title: String
    let key: String
    let fallback: Int
    let minimum: Int
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack {
            Text(LocalizedStringKey(title))
            Spacer()
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 68)
                .focused($editing)
                .accessibilityLabel(LocalizedStringKey(title))
                .onSubmit(commit)
            Text("分钟").foregroundStyle(.secondary)
        }
        .onAppear { text = String(UserDefaults.standard.object(forKey: key) as? Int ?? fallback) }
        .onChange(of: text) { value in
            if let minutes = Self.validMinutes(value, minimum: minimum) {
                UserDefaults.standard.set(minutes, forKey: key)
            }
        }
        .onChange(of: editing) { if !$0 { commit() } }
    }

    static func validMinutes(_ text: String, minimum: Int) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value >= minimum, value <= Int.max / 60 else { return nil }
        return value
    }

    private func commit() {
        text = String(Self.validMinutes(text, minimum: minimum)
                      ?? (UserDefaults.standard.object(forKey: key) as? Int ?? fallback))
    }
}

/// 滑动只改变局部预览；一次手势结束后才持久化并更新其它窗口。
@MainActor
final class TypographyAdjustment: ObservableObject {
    @Published var scale: Double { didSet { if !editing { apply() } } }
    @Published var spacing: Double { didSet { if !editing { apply() } } }
    private var editing = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = AppTypography(scale: defaults.object(forKey: Prefs.uiScale) as? Double ?? 1,
                                  lineSpacing: defaults.object(forKey: Prefs.lineSpacing) as? Double ?? 2)
        scale = saved.scale
        spacing = saved.lineSpacing
    }

    func setEditing(_ editing: Bool) {
        self.editing = editing
        if !editing { apply() }
    }

    private func apply() {
        let value = AppTypography(scale: scale, lineSpacing: spacing)
        if defaults.double(forKey: Prefs.uiScale) != value.scale { defaults.set(value.scale, forKey: Prefs.uiScale) }
        if (defaults.object(forKey: Prefs.lineSpacing) as? Double ?? 2) != value.lineSpacing {
            defaults.set(Double(value.lineSpacing), forKey: Prefs.lineSpacing)
        }
    }
}

struct TypographySettings: View {
    @StateObject private var adjustment = TypographyAdjustment()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("整体字号")
                Spacer()
                Text("\(Int((adjustment.scale * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            Slider(value: $adjustment.scale, in: 0.80...1.50, step: 0.01, onEditingChanged: adjustment.setEditing)
            HStack {
                Text("行间距")
                Spacer()
                Text("\(String(format: "%.1f", adjustment.spacing)) pt")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            Slider(value: $adjustment.spacing, in: 0...10, step: 0.5, onEditingChanged: adjustment.setEditing)
            Text("阅读与记录\n留一点时间给想法。")
                .font(.system(size: 13 * adjustment.scale))
                .lineSpacing(adjustment.spacing)
                .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62, alignment: .leading)
                .padding(.horizontal, 10)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 6))
                .clipped()
        }
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
