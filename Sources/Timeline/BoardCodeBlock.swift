import AppKit
import SwiftUI

/// Native rendering keeps notes lightweight even when a tag contains many boards.
struct BoardCodeBlock: View {
    let code: MarkdownCodeFragment
    @State private var copied = false
    @State private var feedback: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !code.language.isEmpty {
                    Text(code.language).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(code.content, forType: .string)
                    feedback?.cancel()
                    feedback = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(1600)) } catch { return }
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制代码", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(copied ? Palette.success.opacity(0.15) : Palette.background, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(copied ? Palette.success : Palette.accent.opacity(0.4)))
                }
                .buttonStyle(.plain).foregroundStyle(copied ? Palette.success : Palette.accent)
            }
            ScrollView(.horizontal) {
                Text(code.content.hasSuffix("\n") ? String(code.content.dropLast()) : code.content)
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.ink)
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.soft.opacity(0.82), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
        .onDisappear { feedback?.cancel() }
    }
}
