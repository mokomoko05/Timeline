import SwiftUI

/// 界面语言：默认跟随系统，也可以在设置里固定成中文或英文（和 Mac 版同一套做法）。
/// 中文原文就是查表的键，`en.lproj/Localizable.strings` 里是英文；查不到时显示中文原文。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese, english
    static let key = "appLanguage"
    var id: String { rawValue }

    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .system
    }

    var title: String {
        switch self { case .system: return "跟随系统 / System"; case .chinese: return "中文"; case .english: return "English" }
    }

    /// 实际使用的语言：`zh-Hans` 或 `en`。
    var identifier: String {
        switch self {
        case .system: return Bundle.preferredLocalizations(from: ["zh-Hans", "en"], forPreferences: Locale.preferredLanguages).first ?? "zh-Hans"
        case .chinese: return "zh-Hans"
        case .english: return "en"
        }
    }

    var locale: Locale { Locale(identifier: identifier) }

    fileprivate var bundle: Bundle {
        Bundle.main.path(forResource: identifier, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}

/// 不经过 `Text` 字面量的文字（拼出来的字符串、通知、实时活动）按当前语言查表。
func L(_ key: String) -> String {
    AppLanguage.current.bundle.localizedString(forKey: key, value: key, table: nil)
}

/// 带参数的文字：键里的参数写成 `%@`、`%lld`。
func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: AppLanguage.current.locale, arguments: arguments)
}

@MainActor
final class LanguageStore: ObservableObject {
    @Published private(set) var language = AppLanguage.current

    func set(_ value: AppLanguage) {
        guard value != language else { return }
        UserDefaults.standard.set(value.rawValue, forKey: AppLanguage.key)
        language = value
    }
}

extension Date {
    /// 日期格式跟着应用里选的语言走，而不是系统语言。
    func formatted(_ style: Date.FormatStyle) -> String {
        style.locale(AppLanguage.current.locale).format(self)
    }

    func formatted(_ style: Date.RelativeFormatStyle) -> String {
        var style = style
        style.locale = AppLanguage.current.locale
        return style.format(self)
    }
}
