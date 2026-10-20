import SwiftUI

/// 设置中只保留外观切换，使用统一的 GitHub 蓝灰配色。
struct ThemePicker: View {
    @ObservedObject var themes: ThemeStore

    var body: some View {
        Picker("外观", selection: Binding(get: { themes.appearance }, set: themes.setAppearance)) {
            ForEach(AppearanceMode.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
        }.pickerStyle(.segmented)
    }
}
