import SwiftUI
import TimelineCore

/// 删除之类的操作做完后，底部浮出一句说明和「撤销」按钮，几秒后自己消失。整个应用一份，挂在根视图上。
@MainActor final class UndoToast: ObservableObject {
    static let shared = UndoToast()

    @Published private(set) var message: String?
    private var undo: (() -> Void)?
    private var hide: Task<Void, Never>?
    /// 停留时间：给手指移过去点「撤销」留够时间。
    static let duration: TimeInterval = 4

    func show(_ text: String, undo: @escaping () -> Void) {
        self.undo = undo
        withAnimation(Motion.fading(.snappy)) { message = text }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func performUndo() {
        undo?()
        dismiss()
    }

    func dismiss() {
        hide?.cancel()
        undo = nil
        withAnimation(Motion.fading(.easeOut)) { message = nil }
    }

    /// 删除待办，提示里可以撤销。修改本身会在后台写盘（进后台时还会再存一次），这里不在主线程上同步保存。
    static func deleteTodo(_ id: UUID, on date: Date, store: JournalStore) {
        store.deleteTodo(id, on: date)
        shared.show(L("已删除待办")) { store.undo() }
    }
}

struct UndoToastView: View {
    @ObservedObject var toast = UndoToast.shared

    var body: some View {
        if let message = toast.message {
            HStack(spacing: 14) {
                Text(message).font(.subheadline.weight(.medium))
                Button("撤销", action: toast.performUndo)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
            .foregroundStyle(.white)
            .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 10)
            .background(.black.opacity(0.8), in: Capsule())
            .transition(Motion.transition(.move(edge: .bottom).combined(with: .opacity)))
            .padding(.bottom, 64)
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: Text("撤销"), toast.performUndo)
        }
    }
}
