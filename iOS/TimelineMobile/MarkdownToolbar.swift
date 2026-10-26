import TimelineCore
import UIKit

/// 编辑工作板时键盘上方的一排格式按钮：标题、加粗、斜体、代码、链接、列表、勾选、编号、引用、缩进，加上撤销 / 重做和收起键盘。
/// 按钮多，横向可以滑；收起键盘固定在最右边。每个按钮都是一次纯文字替换（`MarkdownEditing`），走编辑器自己的撤销。
@MainActor protocol MarkdownToolbarTarget: AnyObject {
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    func undo()
    func redo()
    func dismissKeyboard()
    /// 按现在的全文和选区（UTF-16）算出替换并应用。
    func format(_ edit: @escaping (String, NSRange) -> MarkdownEdit)
}

final class MarkdownToolbar: UIInputView {
    private weak var target: MarkdownToolbarTarget?
    private var undoButton: UIButton?
    private var redoButton: UIButton?

    init(target: MarkdownToolbarTarget) {
        self.target = target
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 46) }

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 2
        stack.alignment = .center
        scroll.addSubview(stack)

        undoButton = button("arrow.uturn.backward", L("撤销")) { $0.undo() }
        redoButton = button("arrow.uturn.forward", L("重做")) { $0.redo() }
        let items: [UIView] = [
            undoButton!, redoButton!, divider(),
            button("number", L("标题")) { view in MarkdownEditing.cycleHeading(in: view.text, selection: view.selectedRange) },
            button("bold", L("加粗")) { view in MarkdownEditing.wrap("**", in: view.text, selection: view.selectedRange) },
            button("italic", L("斜体")) { view in MarkdownEditing.wrap("*", in: view.text, selection: view.selectedRange) },
            button("chevron.left.forwardslash.chevron.right", L("代码")) { view in MarkdownEditing.wrap("`", in: view.text, selection: view.selectedRange) },
            button("link", L("链接")) { view in MarkdownEditing.link(in: view.text, selection: view.selectedRange) },
            divider(),
            button("checklist", L("待办")) { view in MarkdownEditing.toggle(.task, in: view.text, selection: view.selectedRange) },
            button("list.bullet", L("列表")) { view in MarkdownEditing.toggle(.bullet, in: view.text, selection: view.selectedRange) },
            button("list.number", L("编号")) { view in MarkdownEditing.toggle(.numbered, in: view.text, selection: view.selectedRange) },
            button("text.quote", L("引用")) { view in MarkdownEditing.toggle(.quote, in: view.text, selection: view.selectedRange) },
            button("increase.indent", L("缩进")) { view in MarkdownEditing.indent(in: view.text, selection: view.selectedRange) },
            button("decrease.indent", L("取消缩进")) { view in MarkdownEditing.indent(in: view.text, selection: view.selectedRange, outdent: true) },
        ]
        items.forEach(stack.addArrangedSubview)

        let dismiss = UIButton(type: .system, primaryAction: UIAction(image: UIImage(systemName: "keyboard.chevron.compact.down")) { [weak self] _ in
            self?.target?.dismissKeyboard()
        })
        dismiss.accessibilityLabel = L("收起键盘")
        dismiss.tintColor = UIColor(Palette.muted)

        [scroll, stack, dismiss].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(scroll)
        addSubview(dismiss)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -4),
            dismiss.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            dismiss.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismiss.widthAnchor.constraint(equalToConstant: 44),
            dismiss.heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        refreshUndo()
    }

    /// 文字变了：撤销 / 重做按钮跟着亮灭。
    func refreshUndo() {
        undoButton?.isEnabled = target?.canUndo == true
        redoButton?.isEnabled = target?.canRedo == true
    }

    private func button(_ symbol: String, _ label: String, edit: @escaping (Source) -> MarkdownEdit) -> UIButton {
        button(symbol, label) { target in target.format { text, selection in edit(Source(text: text, selectedRange: selection)) } }
    }

    /// 按钮算替换时看到的全文和选区（和 `UITextView` 的同名属性一样）。
    struct Source {
        let text: String
        let selectedRange: NSRange
    }

    private func button(_ symbol: String, _ label: String, perform: @escaping (MarkdownToolbarTarget) -> Void) -> UIButton {
        let button = UIButton(type: .system, primaryAction: UIAction(image: UIImage(systemName: symbol)) { [weak self] _ in
            guard let target = self?.target else { return }
            perform(target)
        })
        button.accessibilityLabel = label
        button.tintColor = UIColor(Palette.ink)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 40), button.heightAnchor.constraint(equalToConstant: 40)])
        return button
    }

    private func divider() -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor(Palette.line)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([line.widthAnchor.constraint(equalToConstant: 1), line.heightAnchor.constraint(equalToConstant: 20)])
        let holder = UIView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: 9), holder.heightAnchor.constraint(equalToConstant: 40),
            line.centerXAnchor.constraint(equalTo: holder.centerXAnchor), line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }
}
