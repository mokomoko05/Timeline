import SwiftUI
import UIKit

/// 面板一出现就要输入的文本框：加进窗口的那一刻就成为第一响应者，键盘和面板一起升起来。
/// SwiftUI 的 `@FocusState` 要等面板的动画走完才生效：面板先停在半高，键盘再出来把它顶上去，看起来是两段动画。
/// 高度随内容在 `minLines`…`maxLines` 行之间变化，超过后在框里滚动。`submit` 不为 nil 时回车是提交、不换行。
struct AutoFocusTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var minLines = 1
    var maxLines = 8
    var submit: (() -> Void)?
    /// 输入 `@` / `#` 时弹出的补全：改字、挪光标时报给它。
    var mention: MentionModel?

    func makeUIView(context: Context) -> AutoFocusUITextView {
        let view = AutoFocusUITextView()
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
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

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AutoFocusTextView

        init(parent: AutoFocusTextView) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
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
    private var focusedOnce = false

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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !focusedOnce else { return }
        focusedOnce = true
        becomeFirstResponder()
    }
}
