import AppKit

/// 窗口隐藏太久就释放里面的界面（视图、文字排版、图层位图），下次显示前重建。
/// 主窗口、笔记、工作板关掉其实只是隐藏，界面一直占着内存；长时间后台运行时这部分是大头。
///
/// - 隐藏满 `delay` 才释放，短暂切走再回来没有任何重建开销。实测（真实数据）：工作板释放编辑器网页省 30–50MB，
///   重新打开多约 130ms；主窗口省约 20MB，重新打开多约 200ms，所以主窗口等得更久。笔记窗口只省约 5MB，不释放。
/// - 释放前先提交所有编辑（草稿写回数据）；光标还停在有字的输入框里就不释放，下次隐藏再说。
/// - 显示的地方先调用 `restoreIfNeeded()`，重建好再显示，不会闪出空窗口；漏掉的显示路径由可见性通知兜底。
@MainActor
final class HiddenContentReleaser {
    /// 测试里统一改成很短的时间。
    static var delayOverride: Duration?

    private let delay: Duration
    private weak var window: NSWindow?
    /// 这时不释放：界面里还有没保存、也提交不了的内容（改到一半的任务标题）。
    private let keep: () -> Bool
    private let release: () -> Void
    private let rebuild: () -> Void
    private(set) var released = false
    private var pending: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init(window: NSWindow, delay: Duration, keep: @escaping () -> Bool = { false }, release: @escaping () -> Void, rebuild: @escaping () -> Void) {
        self.delay = delay
        self.keep = keep
        self.window = window
        self.release = release
        self.rebuild = rebuild
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityChanged() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 显示窗口之前调用：界面释放过就先重建。
    func restoreIfNeeded() {
        pending?.cancel()
        pending = nil
        guard released else { return }
        released = false
        rebuild()
    }

    /// 窗口刚隐藏（关窗口、收起的地方调用；可见性通知也会调用）：开始计时。
    func windowHidden() {
        guard let window, !window.isVisible, !released, pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.delayOverride ?? self?.delay ?? .seconds(300))
            guard !Task.isCancelled else { return }
            self?.pending = nil
            self?.releaseIfStillHidden()
        }
    }

    private func visibilityChanged() {
        guard let window else { return }
        if window.isVisible { restoreIfNeeded() } else { windowHidden() }
    }

    /// 不等计时，窗口隐藏着就立刻释放（测量用）。
    func releaseNow() {
        pending?.cancel()
        pending = nil
        releaseIfStillHidden()
    }

    private func releaseIfStillHidden() {
        guard let window, !window.isVisible, !released else { return }
        NotificationCenter.default.post(name: .timelineCommitEditing, object: nil)
        if let editor = window.firstResponder as? NSTextView, editor.isEditable, !editor.string.isEmpty { return }
        if keep() { return }
        released = true
        release()
        ImageTools.purgeThumbnails()
    }
}
