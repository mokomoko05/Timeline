import SwiftUI
import UIKit

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

/// 给某条待办记一笔：卡片在列表里，输入卡得挂在整页上，由页面放进环境。
struct TaskNoteWriter {
    let write: (UUID) -> Void
    func callAsFunction(_ id: UUID) { write(id) }
}

private struct TaskNoteWriterKey: EnvironmentKey {
    static let defaultValue: TaskNoteWriter? = nil
}

extension EnvironmentValues {
    var writeTaskNote: TaskNoteWriter? {
        get { self[TaskNoteWriterKey.self] }
        set { self[TaskNoteWriterKey.self] = newValue }
    }

    /// 在输入卡里时有值：输入面板据此换成卡片的样子，收起时调它（不是 `dismiss`）。
    var closeEditor: EditorCloser? {
        get { self[EditorCloserKey.self] }
        set { self[EditorCloserKey.self] = newValue }
    }
}

/// 开关卡片只通知 overlay，避免让底下的日记全文随之重新计算。
@MainActor
final class EditorPresentation: ObservableObject {
    @Published var shown = false
}

private struct PresentedEditor<Content: View>: View {
    @ObservedObject var presentation: EditorPresentation
    @ViewBuilder var content: () -> Content
    var body: some View {
        FloatingEditorHost(shown: presentation.shown, close: { presentation.shown = false }, content: content)
    }
}

extension View {
    func floatingEditor<Content: View>(presentation: EditorPresentation, @ViewBuilder content: @escaping () -> Content) -> some View {
        overlay { PresentedEditor(presentation: presentation, content: content) }
    }

    func floatingEditor<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        overlay { FloatingEditorHost(shown: isPresented.wrappedValue, close: { isPresented.wrappedValue = false }, content: content) }
    }

    /// 按某一项打开的输入卡（给哪条待办记笔记、改哪条日志）。收起的动画里还要接着画那一项，所以记住上一次的。
    func floatingEditor<Item, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        overlay { FloatingItemEditor(item: item, content: content) }
    }
}

private struct FloatingItemEditor<Item, Content: View>: View {
    @Binding var item: Item?
    let content: (Item) -> Content
    @State private var last: Item?

    var body: some View {
        FloatingEditorHost(shown: item != nil, close: { item = nil }) {
            if let current = item ?? last { content(current) }
        }
        .onChange(of: item != nil) { _, shown in if shown { last = item } }
    }
}

private struct FloatingEditorHost<Content: View>: View {
    let shown: Bool
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .bottom) {
            if shown {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture(perform: dismiss)
                    .transition(.opacity)
                content()
                    .environment(\.closeEditor, EditorCloser(close: dismiss))
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
                    // 收起时卡片已经跟着键盘往下走了，再叠一个滑出会在底部停一下；只淡掉。
                    .transition(Motion.transition(.asymmetric(insertion: .move(edge: .bottom), removal: .opacity)))
            }
        }
        .animation(Motion.adapt(.snappy(duration: 0.22)), value: shown)
        // 从外面收起（比如存完了）时也立刻放下键盘。
        .onChange(of: shown) { _, shown in if !shown { Self.dropKeyboard() } }
    }

    /// 先让键盘开始收，再撤卡片：键盘和卡片一起往下走。
    /// 要是只撤卡片，输入框要等退场动画放完、真的离开窗口才交出焦点，键盘就会在原地停一下再收。
    private func dismiss() {
        Self.dropKeyboard()
        close()
    }

    static func dropKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
