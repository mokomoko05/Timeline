import SwiftUI

/// 设置里的配色选择：每套配色一张小卡片，左半是浅色版本、右半是深色版本的缩略预览，选中的描边。
struct ThemePicker: View {
    @ObservedObject var themes: ThemeStore
    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("外观", selection: Binding(get: { themes.appearance }, set: themes.setAppearance)) {
                ForEach(AppearanceMode.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
            }.pickerStyle(.segmented)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(AppTheme.all) { theme in card(theme) }
            }
        }
    }

    private func card(_ theme: AppTheme) -> some View {
        let chosen = theme.id == themes.themeID
        return Button { themes.select(theme.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    preview(theme.light)
                    preview(theme.dark)
                }
                .frame(height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(theme.name)).font(.system(size: 12, weight: chosen ? .semibold : .regular))
                    Spacer(minLength: 0)
                    if chosen { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).fill(chosen ? Color.accentColor.opacity(0.10) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chosen ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(LocalizedStringKey(theme.subtitle))
        .accessibilityLabel("配色：\(theme.name)")
        .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
    }

    /// 一半预览：底色上一张卡片、一行文字线、强调色和两个状态色的圆点。
    private func preview(_ colors: ThemeColors) -> some View {
        func color(_ hex: UInt32) -> Color {
            Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
        }
        return ZStack {
            color(colors.background)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(color(colors.ink)).frame(width: 30, height: 4)
                RoundedRectangle(cornerRadius: 2).fill(color(colors.muted)).frame(width: 20, height: 3)
                HStack(spacing: 3) {
                    Circle().fill(color(colors.accent)).frame(width: 8, height: 8)
                    Circle().fill(color(colors.success)).frame(width: 8, height: 8)
                    Circle().fill(color(colors.deadline)).frame(width: 8, height: 8)
                }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            .background(color(colors.card), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color(colors.line)))
            .padding(6)
        }
    }
}
