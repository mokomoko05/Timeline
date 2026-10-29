import SwiftUI
import UIKit

/// 面板输入框：首次先呈现卡片再初始化系统键盘，后续挂入窗口立即获取焦点。
/// 高度和焦点由 UIKit 桥接控制，避免等待 SwiftUI 的面板动画完成才进入输入状态。
/// 高度随内容在 `minLines`…`maxLines` 行之间变化，超过后在框里滚动。`submit` 不为 nil 时回车是提交、不换行。
struct AutoFocusTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var minLines = 1
    var maxLines = 8
    var submit: (() -> Void)?
    /// 输入 `@` / `#` 时弹出的补全：改字、挪光标时报给它。
    var mention: MentionModel?
    /// 保存等待期间拒绝输入，保留焦点到正常退场；不要用 disabled 强迫键盘切换。
    var acceptsEdits: () -> Bool = { true }

    func makeUIView(context: Context) -> AutoFocusUITextView {
        let started = CACurrentMediaTime()
        defer { if PerfProbe.enabled { print("[perf] EDITOR makeTextViewMS=\((CACurrentMediaTime() - started) * 1000)") } }
        let view = EditorInputPool.take()
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.acceptsEdits = acceptsEdits
        view.returnKeyType = submit == nil ? .default : .done
        view.placeholder.text = placeholder
        view.text = text
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let mention {
            mention.textView = view
            mention.textEdited = { [weak view, coordinator = context.coordinator] in
                guard let view else { return }
                coordinator.textViewDidChange(view)
            }
        }
        return view
    }

    func updateUIView(_ view: AutoFocusUITextView, context: Context) {
        context.coordinator.parent = self
        view.acceptsEdits = acceptsEdits
        if view.text != text, view.markedTextRange == nil { view.text = text }
        view.placeholder.text = placeholder
        view.placeholder.isHidden = !view.text.isEmpty
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: AutoFocusUITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let line = view.font?.lineHeight ?? 20
        let insets = view.textContainerInset.top + view.textContainerInset.bottom
        let natural = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(natural, line * CGFloat(minLines) + insets), line * CGFloat(maxLines) + insets)
        view.isScrollEnabled = natural > height
        return CGSize(width: width, height: ceil(height))
    }

    static func dismantleUIView(_ view: AutoFocusUITextView, coordinator: Coordinator) {
        if coordinator.parent.mention?.textView === view {
            coordinator.parent.mention?.textView = nil
            coordinator.parent.mention?.textEdited = {}
        }
        view.delegate = nil
        view.acceptsEdits = { true }
        EditorInputPool.recycle(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AutoFocusTextView

        init(parent: AutoFocusTextView) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard parent.acceptsEdits() else { return false }
            guard text == "\n", let submit = parent.submit, textView.markedTextRange == nil else { return true }
            submit()
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? AutoFocusUITextView)?.placeholder.isHidden = !textView.text.isEmpty
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
            parent.mention?.update(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.mention?.update(textView)
        }
    }
}

final class AutoFocusUITextView: UITextView {
    let placeholder = UILabel()
    var acceptsEdits: () -> Bool = { true }
    private var focusedOnce = false
    private static var keyboardActivated = false
    private var focusLink: CADisplayLink?
    private var focusFrames = 0

    func prepareForReuse() {
        focusedOnce = false
        text = ""
        placeholder.isHidden = false
        contentOffset = .zero
        undoManager?.removeAllActions()
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.font = UIFont.preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.numberOfLines = 0
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: frameLayoutGuide.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: frameLayoutGuide.topAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // UITextInput 的直接输入路径未必经过 UITextViewDelegate；保存时两层都要拦住。
    override func insertText(_ text: String) {
        guard acceptsEdits() else { return }
        super.insertText(text)
    }

    override func deleteBackward() {
        guard acceptsEdits() else { return }
        super.deleteBackward()
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard acceptsEdits() else { return }
        super.setMarkedText(markedText, selectedRange: selectedRange)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { focusLink?.invalidate(); focusLink = nil; return }
        guard !focusedOnce, focusLink == nil else { return }
        if Self.keyboardActivated { activateKeyboard(); return }
        // 先提交卡片首帧，再初始化系统键盘，避免两项主线程工作挤在同一帧。
        focusFrames = 0
        let link = CADisplayLink(target: self, selector: #selector(focusAfterFrame))
        focusLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func focusAfterFrame() {
        focusFrames += 1
        guard focusFrames >= 2 else { return }
        focusLink?.invalidate(); focusLink = nil
        guard window != nil, !focusedOnce else { return }
        activateKeyboard()
    }

    private func activateKeyboard() {
        let started = CACurrentMediaTime()
        focusedOnce = becomeFirstResponder()
        if focusedOnce { Self.keyboardActivated = true }
        if PerfProbe.enabled { print("[perf] EDITOR focusMS=\((CACurrentMediaTime() - started) * 1000)") }
    }

}

/// 只预热未挂载的输入框和公开输入模式查询，不抢焦点、不显示键盘。
@MainActor
enum EditorInputPool {
    private static var cached: AutoFocusUITextView?
    private static var warmed = false

    static func warmUp() {
        guard !warmed else { return }
        warmed = true
        let start = CACurrentMediaTime()
        let view = AutoFocusUITextView()
        view.font = UIFont.preferredFont(forTextStyle: .body)
        _ = UITextInputMode.activeInputModes
        _ = view.textInputMode
        _ = view.sizeThatFits(CGSize(width: 320, height: 200))
        cached = view
        if PerfProbe.enabled { print("[perf] EDITOR warmInputMS=\((CACurrentMediaTime() - start) * 1000)") }
    }

    static func take() -> AutoFocusUITextView {
        let view = cached ?? AutoFocusUITextView()
        cached = nil
        return view
    }

    static func recycle(_ view: AutoFocusUITextView) {
        guard !view.isFirstResponder, cached == nil else { return }
        view.prepareForReuse()
        cached = view
    }
}
