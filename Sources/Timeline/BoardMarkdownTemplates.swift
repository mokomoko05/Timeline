import AppKit

enum BoardMarkdownTemplate {
    case disclosure, paper, meeting

    struct Insertion {
        let source: String
        let replacement: String
        let replacedRange: NSRange
        let selectedRange: NSRange
    }

    func insertion(into source: String, selection: NSRange? = nil) -> Insertion {
        let text = source as NSString
        let range = selection.flatMap { $0.location <= text.length && $0.length <= text.length - $0.location ? $0 : nil }
            ?? NSRange(location: text.length, length: 0)
        let selected = text.substring(with: range)
        let content: String
        let placeholder: String
        switch self {
        case .disclosure:
            placeholder = AppLocalized("折叠标题")
            content = "<details>\n<summary>" + placeholder + "</summary>\n\n"
                + (selected.isEmpty ? AppLocalized("在这里填写内容，支持 Markdown、链接和待办。") : selected)
                + "\n\n</details>"
        case .paper:
            placeholder = AppLocalized("论文阅读")
            content = "# " + placeholder + "\n\n- [ ] Intro & Abstract\n- [ ] Background\n- [ ] Design\n- [ ] Experiment\n\n## "
                + AppLocalized("阅读笔记") + "\n\n"
        case .meeting:
            placeholder = AppLocalized("会议议程")
            content = "# " + placeholder + "\n\n## " + AppLocalized("进展同步")
                + "\n\n## " + AppLocalized("讨论事项") + "\n\n## " + AppLocalized("结论与后续行动") + "\n\n"
        }
        let before = text.substring(to: range.location)
        let after = text.substring(from: NSMaxRange(range))
        let prefix = before.isEmpty || before.hasSuffix("\n\n") ? "" : (before.hasSuffix("\n") ? "\n" : "\n\n")
        let suffix = after.isEmpty || after.hasPrefix("\n\n") ? "" : (after.hasPrefix("\n") ? "\n" : "\n\n")
        let replacement = prefix + content + suffix
        let placeholderRange = (replacement as NSString).range(of: placeholder)
        return Insertion(source: text.replacingCharacters(in: range, with: replacement), replacement: replacement,
                         replacedRange: range,
                         selectedRange: NSRange(location: range.location + placeholderRange.location,
                                                length: placeholderRange.length))
    }

    @discardableResult
    func insert(into editor: NSTextView) -> Bool {
        guard editor.isEditable, !editor.hasMarkedText() else { return false }
        let insertion = insertion(into: editor.string, selection: editor.selectedRange())
        editor.insertText(insertion.replacement, replacementRange: insertion.replacedRange)
        editor.setSelectedRange(insertion.selectedRange)
        editor.scrollRangeToVisible(insertion.selectedRange)
        editor.window?.makeFirstResponder(editor)
        return true
    }
}
