import SwiftUI

/// 写一笔、新待办的输入卡：贴在键盘上面，和键盘一起一下子升起来。
/// 系统面板（`.sheet`）先走自己的弹簧动画（约 0.5 秒）、再被键盘顶到位，看起来拖沓；这里是页面上的一层，
/// 背景变暗、卡片从底下滑上来只用 0.22 秒，点暗处或「取消」收起。
struct EditorCloser {
    let close: () -> Void
    func callAsFunction() { close() }
}

private struct EditorCloserKey: EnvironmentKey {
    static let defaultValue: EditorCloser? = nil
}

extension EnvironmentValues {
    /// 在输入卡里时有值：输入面板据此换成卡片的样子，收起时调它（不是 `dismiss`）。
    var closeEditor: EditorCloser? {
        get { self[EditorCloserKey.self] }
        set { self[EditorCloserKey.self] = newValue }
    }
}

extension View {
    func floatingEditor<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        overlay { FloatingEditorHost(isPresented: isPresented, content: content) }
    }
}

private struct FloatingEditorHost<Content: View>: View {
    @Binding var isPresented: Bool
    let content: () -> Content

    var body: some View {
        ZStack(alignment: .bottom) {
            if isPresented {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { isPresented = false }
                    .transition(.opacity)
                content()
                    .environment(\.closeEditor, EditorCloser { isPresented = false })
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                    .background {
                        UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20, style: .continuous)
                            .fill(Palette.card)
                            .shadow(color: .black.opacity(0.12), radius: 10, y: -2)
                            .ignoresSafeArea(edges: .bottom)
                    }
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.snappy(duration: 0.22), value: isPresented)
    }
}

/// 输入卡的标题行：取消 · 标题 · 保存。
struct EditorCardHeader: View {
    let title: LocalizedStringKey
    let confirm: LocalizedStringKey
    let canConfirm: Bool
    let cancel: () -> Void
    let action: () -> Void

    var body: some View {
        HStack {
            Button("取消", action: cancel)
            Spacer()
            Text(title).font(.headline).foregroundStyle(Palette.ink)
            Spacer()
            Button(action: action) { Text(confirm).fontWeight(.semibold) }.disabled(!canConfirm)
        }
        .padding(.bottom, 2)
    }
}
