import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 全局快捷键的动作。
enum HotKeyAction: String, CaseIterable, Identifiable {
    case main, shell, log, notes, focusPanel, board, search
    var id: String { rawValue }

    var title: String {
        switch self {
        case .main: return "打开 / 隐藏 Timeline"
        case .shell: return "打开 / 隐藏内置终端"
        case .log: return "快速写日志"
        case .notes: return "打开 / 关闭笔记"
        case .focusPanel: return "显示 / 隐藏专注计时"
        case .board: return "显示 / 隐藏工作板"
        case .search: return "打开 / 关闭全局搜索"
        }
    }

    var identifier: UInt32 {
        switch self { case .log: return 2; case .main: return 3; case .shell: return 4; case .notes: return 5; case .focusPanel: return 6; case .board: return 7; case .search: return 8 }
    }

    var defaultBinding: HotKeyBinding {
        switch self {
        case .main: return HotKeyBinding(keyCode: kVK_ANSI_D, modifiers: HotKeyBinding.controlOption)
        case .shell: return HotKeyBinding(keyCode: kVK_Tab, modifiers: controlKey)
        case .log: return HotKeyBinding(keyCode: kVK_ANSI_L, modifiers: HotKeyBinding.controlOption)
        case .notes: return HotKeyBinding(keyCode: kVK_ANSI_N, modifiers: HotKeyBinding.controlOption)
        case .focusPanel: return HotKeyBinding(keyCode: kVK_ANSI_F, modifiers: HotKeyBinding.controlOption)
        case .board: return HotKeyBinding(keyCode: kVK_ANSI_M, modifiers: HotKeyBinding.controlOption)
        case .search: return HotKeyBinding(keyCode: kVK_ANSI_S, modifiers: HotKeyBinding.controlOption)
        }
    }

    var storageKey: String { "hotkey.\(rawValue)" }
}

/// 一个按键组合：虚拟键码加 Carbon 修饰键。
struct HotKeyBinding: Equatable, Codable {
    var keyCode: Int
    /// Carbon 修饰键（cmdKey / shiftKey / optionKey / controlKey 的组合）。
    var modifiers: Int

    static let controlOption = controlKey | optionKey

    /// 全局快捷键至少要有一个修饰键，否则会吞掉正常打字。
    var isValid: Bool { modifiers & (cmdKey | optionKey | controlKey) != 0 }

    var label: String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.command) { result |= cmdKey }
        return result
    }

    private static let names: [Int: String] = [
        kVK_Space: "空格", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G",
        kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N",
        kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U",
        kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]

    static func keyName(_ code: Int) -> String { names[code] ?? AppLocalizedFormat("键码%lld", code) }

    private static let functionKeys: [Int: Int] = [
        kVK_F1: 0, kVK_F2: 1, kVK_F3: 2, kVK_F4: 3, kVK_F5: 4, kVK_F6: 5,
        kVK_F7: 6, kVK_F8: 7, kVK_F9: 8, kVK_F10: 9, kVK_F11: 10, kVK_F12: 11,
    ]

    /// 作为菜单项快捷键使用时的字符和修饰键。
    var menuEquivalent: (key: String, mask: NSEvent.ModifierFlags) {
        var mask: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { mask.insert(.control) }
        if modifiers & optionKey != 0 { mask.insert(.option) }
        if modifiers & shiftKey != 0 { mask.insert(.shift) }
        if modifiers & cmdKey != 0 { mask.insert(.command) }
        func special(_ code: Int) -> String { String(UnicodeScalar(UInt32(code))!) }
        let key: String
        switch keyCode {
        case kVK_Space: key = " "
        case kVK_Return: key = "\r"
        case kVK_Tab: key = "\t"
        case kVK_Delete: key = "\u{8}"
        case kVK_Escape: key = "\u{1b}"
        case kVK_LeftArrow: key = special(NSLeftArrowFunctionKey)
        case kVK_RightArrow: key = special(NSRightArrowFunctionKey)
        case kVK_UpArrow: key = special(NSUpArrowFunctionKey)
        case kVK_DownArrow: key = special(NSDownArrowFunctionKey)
        default:
            if let index = Self.functionKeys[keyCode] { key = special(NSF1FunctionKey + index) }
            else { key = Self.keyName(keyCode).lowercased() }
        }
        return (key, mask)
    }

    /// 能显示和注册的按键（有名字的）。
    static func isSupportedKey(_ code: Int) -> Bool { names[code] != nil }
}

/// 绑定的读取、保存和冲突检查。
enum HotKeyStore {
    static func binding(for action: HotKeyAction, defaults: UserDefaults = .standard) -> HotKeyBinding {
        guard let data = defaults.data(forKey: action.storageKey),
              let saved = try? JSONDecoder().decode(HotKeyBinding.self, from: data), saved.isValid else { return action.defaultBinding }
        return saved
    }

    static func save(_ binding: HotKeyBinding?, for action: HotKeyAction, defaults: UserDefaults = .standard) {
        if let binding, let data = try? JSONEncoder().encode(binding) { defaults.set(data, forKey: action.storageKey) }
        else { defaults.removeObject(forKey: action.storageKey) }
    }

    /// 已经被 Timeline 里别的动作使用的绑定，返回那个动作。
    static func conflict(of binding: HotKeyBinding, excluding action: HotKeyAction, defaults: UserDefaults = .standard) -> HotKeyAction? {
        HotKeyAction.allCases.first { $0 != action && Self.binding(for: $0, defaults: defaults) == binding }
    }
}

extension Notification.Name {
    static let timelineHotKeysChanged = Notification.Name("TimelineHotKeysChanged")
}

/// 设置里的按键录制框：点一下进入录制，按下带修饰键的组合即可；Esc 取消。
struct HotKeyRecorder: View {
    let action: HotKeyAction
    @State private var binding: HotKeyBinding
    @State private var recording = false
    @State private var message: String?
    @State private var monitor: Any?

    init(action: HotKeyAction) {
        self.action = action
        _binding = State(initialValue: HotKeyStore.binding(for: action))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(action.title))
                Spacer()
                Button(recording ? AppLocalized("请按下新的组合…") : binding.label) { recording ? stop() : start() }
                    .buttonStyle(.bordered)
                    .frame(minWidth: 120)
                    .help("录入快捷键")
                Button { reset() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).disabled(binding == action.defaultBinding)
                    .help("恢复默认 \(action.defaultBinding.label)").accessibilityLabel("恢复默认")
            }
            if let message { Text(LocalizedStringKey(message)).font(.caption).foregroundStyle(Palette.deadline) }
        }
        .onDisappear { stop() }
    }

    private func start() {
        message = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let candidate = HotKeyBinding(keyCode: Int(event.keyCode), modifiers: HotKeyBinding.carbonModifiers(event.modifierFlags))
            guard HotKeyBinding.isSupportedKey(candidate.keyCode) else { message = AppLocalized("这个键不能用作快捷键"); return nil }
            guard candidate.isValid else { message = AppLocalized("需要至少一个修饰键（⌃ ⌥ ⌘），否则会影响正常打字"); return nil }
            if let other = HotKeyStore.conflict(of: candidate, excluding: action) { message = AppLocalizedFormat("已被「%@」使用", AppLocalized(other.title)); return nil }
            apply(candidate)
            return nil
        }
    }

    private func apply(_ candidate: HotKeyBinding) {
        stop()
        binding = candidate
        HotKeyStore.save(candidate == action.defaultBinding ? nil : candidate, for: action)
        NotificationCenter.default.post(name: .timelineHotKeysChanged, object: nil)
    }

    private func reset() {
        message = nil
        if let other = HotKeyStore.conflict(of: action.defaultBinding, excluding: action) { message = AppLocalizedFormat("默认组合已被「%@」使用，请先改那一个", AppLocalized(other.title)); return }
        apply(action.defaultBinding)
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
