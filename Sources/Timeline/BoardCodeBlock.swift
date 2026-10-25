import AppKit
import SwiftUI

/// Native rendering keeps notes lightweight even when a tag contains many boards.
struct BoardCodeBlock: View {
    let code: MarkdownCodeFragment
    @State private var copied = false
    @State private var feedback: Task<Void, Never>?

    var body: some View {
        ScrollView(.horizontal) {
            Text(code.content.hasSuffix("\n") ? String(code.content.dropLast()) : code.content)
                .font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink)
                .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 右上角留出复制按钮的位置，第一行不被盖住。
                .padding(.trailing, code.language.isEmpty ? 34 : 34 + CGFloat(code.language.count) * 7)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.soft.opacity(0.82), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
        // 语言和复制放在代码块右上角，不单独占一行。
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                if !code.language.isEmpty {
                    Text(code.language).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                }
                Button(action: copy) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        if copied { Text("已复制") }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6).frame(height: 22)
                    .background(copied ? Palette.success.opacity(0.15) : Palette.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(copied ? Palette.success.opacity(0.6) : Palette.line.opacity(0.8), lineWidth: Metrics.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(copied ? Palette.success : Palette.muted)
                .help(copied ? "已复制" : "复制代码").accessibilityLabel(copied ? "已复制" : "复制代码")
            }
            .padding(6)
        }
        .onDisappear { feedback?.cancel() }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(code.content, forType: .string)
        feedback?.cancel()
        feedback = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(1600)) } catch { return }
            copied = false
        }
    }
}
