import QuartzCore
import SwiftUI
import UIKit
import TimelineCore

/// 卡顿探针（启动参数 `-perfProbe YES` 时才工作）：盯着每一帧，主线程被占住超过两帧就打印卡了多久、
/// 发生在哪个操作之后。`-perfScript YES` 再自动走一遍切到日记、换天、切回待办，方便在模拟器里对比优化前后。
@MainActor
enum PerfProbe {
    static let enabled = UserDefaults.standard.bool(forKey: "perfProbe")
    static let scripted = UserDefaults.standard.bool(forKey: "perfScript")
    static let previousDay = Notification.Name("PerfProbePreviousDay")
    static let openCalendar = Notification.Name("PerfProbeOpenCalendar")
    static let pickDay = Notification.Name("PerfProbePickDay")
    /// 截图检查用：滚到当天第几条日志。
    static let revealLog = Notification.Name("PerfProbeRevealLog")
    private static var label = "launch"
    private static var marked = CACurrentMediaTime()
    private static var monitor: FrameMonitor?
    private static var focusNoteID: UUID?
    private static var focusNoteMarker: String?
    private static var focusNoteIsGray = false
    private static var focusNoteHasLabel = false
    private static var focusNoteRenderedAt: CFTimeInterval?

    static func renderedFocusNote(_ log: DailyLogEntry) {
        guard enabled, log.id == focusNoteID else { return }
        focusNoteMarker = log.focusMarker
        focusNoteRenderedAt = CACurrentMediaTime()
        focusNoteIsGray = LogStyle.color(log) == Palette.muted
        focusNoteHasLabel = LogStyle.label(log) != nil
        lap("focus note body \(log.focusMarker)")
    }

    private static func checkFocusNote(_ marker: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let matches = focusNoteMarker == marker && focusNoteIsGray == (marker == "INFO") && !focusNoteHasLabel
            print("[perf] FOCUS_RENDER \(matches ? "PASS" : "FAIL") expected=\(marker) rendered=\(focusNoteMarker ?? "missing") gray=\(focusNoteIsGray) label=\(focusNoteHasLabel)")
        }
    }

    static func start() {
        guard enabled, monitor == nil else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        monitor = FrameMonitor()
    }

    static func mark(_ text: String) {
        guard enabled else { return }
        label = text
        marked = CACurrentMediaTime()
        print("[perf] ▶ \(text)")
    }

    /// 某个操作走到哪一步了：打印距离上一次 `mark` 过了多久。
    static func lap(_ text: String) {
        guard enabled else { return }
        print("[perf]   \(text) +\(Int((CACurrentMediaTime() - marked) * 1000)) ms")
    }

    private static var parsing: CFTimeInterval = 0

    /// 主线程上现解析 Markdown 花的时间，卡顿时一起报出来。
    static func parsed(_ seconds: CFTimeInterval) { if enabled { parsing += seconds } }

    fileprivate static var typesetting: CFTimeInterval = 0
    fileprivate static var drawing: CFTimeInterval = 0

    /// 主线程上现排 / 画 `RichText` 花的时间。
    static func typeset(_ seconds: CFTimeInterval) { if enabled { typesetting += seconds } }
    static func drew(_ seconds: CFTimeInterval) { if enabled { drawing += seconds } }

    fileprivate static func hitch(_ milliseconds: Int) {
        if parsing > 0.001 { print("[perf]   其中主线程解析 Markdown \(Int(parsing * 1000)) ms") }
        parsing = 0
        if typesetting > 0.001 { print("[perf]   其中主线程排正文 \(Int(typesetting * 1000)) ms") }
        if drawing > 0.001 { print("[perf]   其中画正文 \(Int(drawing * 1000)) ms") }
        typesetting = 0
        drawing = 0
        let since = Int((CACurrentMediaTime() - marked) * 1000)
        print("[perf] hitch \(milliseconds) ms · \(since) ms after「\(label)」")
    }

    /// 模拟器测试用（`-demoData YES`）：数据是空的时候放一些待办、日志和标签，拖动排序和 @ / # 搜索才有东西可测。
    static func seedDemo(_ store: JournalStore) {
        guard UserDefaults.standard.bool(forKey: "demoData"), store.tasks().isEmpty else { return }
        let titles = ["查清楚同步的问题 #工作", "整理周报 #工作", "回复邮件", "下午3点 开会 #工作", "买菜 #生活", "跑步 30 分钟 #健康",
                      "明天 读完第三章 #学习", "明天 修自行车 #生活", "后天 准备演示 #工作", "下周一 体检 #健康", "写博客草稿 #写作", "整理照片"]
        for (index, title) in titles.enumerated() {
            _ = store.addParsedTodo(title, on: Date(), priority: index % 4 == 0 ? .high : .normal)
        }
        // `-demoMarkdown "<正文>"`：换掉公式示例，放一条指定的日志（检查某段复制来的 Markdown 怎么显示）。
        let sample = UserDefaults.standard.string(forKey: "demoMarkdown") ?? demoMath
        for text in [sample, "今天把同步的问题查清楚了 #工作", "跑了 5 公里 #健康", "读书笔记：第二章讲的是排版 #学习"] {
            _ = try? store.quickLog(text, on: Date())
        }
        store.save()
    }

    /// 带公式的日志：测公式排版的开销。
    private static let demoMath = (0..<12).map { index in
        "第 \(index + 1) 条：设 $x_\(index) = \\alpha^{\(index)} + \\beta$，则\n\n$$\n\\sum_{k=1}^{\(index + 2)} \\frac{x_k^2}{\\sqrt{k+\(index)}} = \\int_0^{\\infty} e^{-t^{\(index % 3 + 1)}}\\,dt\n$$"
    }.joined(separator: "\n\n") + "\n\n> 引用里的公式 $e^{i\\pi}+1=0$\n\n- [ ] 待办里的公式 $a^2+b^2=c^2$ #学习"

    /// 截图检查用（`-demoFocus YES`）：启动一秒后对第一个未完成的待办开始专注。
    static func demoFocus(_ focus: FocusTimer) {
        guard UserDefaults.standard.bool(forKey: "demoFocus"), !focus.isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let task = TaskSortMode.deadline.sorted(focus.store.tasks()).first(where: { !$0.task.completed }) else { return }
            focus.start(task: task, minutes: 25, goal: "")
        }
    }

    /// 打字测试（`-perfTyping compose|task|board`）：打开对应的输入框，往里一个个字地输入，报每个字从按下到画出来的时间。
    static let typing = UserDefaults.standard.string(forKey: "perfTyping")
    static let openEditor = Notification.Name("PerfProbeOpenEditor")
    private static var keyDown: CFTimeInterval?
    private static var latencies: [Double] = []

    fileprivate static func frameDrawn(at time: CFTimeInterval) {
        if let rendered = focusNoteRenderedAt {
            focusNoteRenderedAt = nil
            print("[perf] FOCUS_FRAME \(focusNoteMarker ?? "missing") mutationToFrameMS=\(Int((time - marked) * 1000)) bodyToFrameMS=\(Int((time - rendered) * 1000))")
        }
        if let (name, start) = pendingAction {
            pendingAction = nil
            print("[perf] 「\(name)」到下一帧 \(Int((time - start) * 1000)) ms")
        }
        guard let start = keyDown else { return }
        latencies.append((time - start) * 1000)
        keyDown = nil
    }

    /// 按钮测试（`-perfActions YES`）：依次模拟点常用的按钮（和按钮做的事一样），报每一下从按下到画出下一帧的时间。
    static let action = Notification.Name("PerfProbeAction")
    private static var pendingAction: (String, CFTimeInterval)?

    static func runActions(switchTab: @escaping (RootView.Tab) -> Void) {
        guard enabled, UserDefaults.standard.bool(forKey: "perfActions") else { return }
        let store = AppServices.shared.store
        let send = { (name: String) in NotificationCenter.default.post(name: action, object: name) }
        let firstOpen = { TaskSortMode.deadline.sorted(store.tasks()).first { !$0.task.completed } }
        var toggled: ScheduledTask?
        let steps: [(String, () -> Void)] = [
            ("完成一个待办", { toggled = firstOpen(); if let item = toggled { store.toggleTodo(item.id, on: item.date) } }),
            ("取消完成", { if let item = toggled { store.toggleTodo(item.id, on: item.date) } }),
            ("删除待办", { if let item = firstOpen() { UndoToast.deleteTodo(item.id, on: item.date, store: store) } }),
            ("撤销删除", { UndoToast.shared.performUndo() }),
            ("打开待办笔记页", { send("openTask") }),
            ("任务设置", { send("editTask") }),
            ("关掉任务设置", { send("closeSheet") }),
            ("返回待办", { send("popTask") }),
            ("新建待办", { send("addTask") }),
            ("关掉新建待办", { send("closeSheet") }),
            ("切到日记", { switchTab(.journal) }),
            ("建立专注笔记", {
                switchTab(.journal)
                if store.focusTaskID == nil, let task = firstOpen() {
                    store.setFocusTask(task.id)
                    store.addFocusLog("▶ 开始专注", taskID: task.id, event: .start)
                }
                if let focusNoteID { store.deleteLog(focusNoteID, on: Date()) }
                focusNoteID = try? store.quickLogEntry("Performance focus note", taskID: store.focusTaskID, on: Date(), focusEvent: .note).entry?.id
                focusNoteMarker = nil
                checkFocusNote("NOTE")
            }),
            ("取消笔记关联", {
                guard let focusNoteID else { return }
                store.setLogTask(nil, forLog: focusNoteID, on: Date())
                checkFocusNote("INFO")
            }),
            ("定位专注笔记", {
                guard let focusNoteID,
                      let index = store.allLogs(includeFocus: true).filter({ JournalDates.calendar.isDateInToday($0.date) })
                        .firstIndex(where: { $0.id == focusNoteID }) else { return }
                NotificationCenter.default.post(name: revealLog, object: index)
            }),
            ("恢复笔记关联", {
                guard let focusNoteID else { return }
                store.setLogTask(store.focusTaskID, forLog: focusNoteID, on: Date())
                checkFocusNote("NOTE")
            }),
            ("记一笔", { send("compose") }),
            ("关掉记一笔", { send("closeSheet") }),
            ("滑动中跳转", { send("flingJump") }),
            ("切到笔记", { switchTab(.notes) }),
            ("切到工作板", { switchTab(.boards) }),
            ("打开工作板", { send("openBoard") }),
            ("切到待办", { switchTab(.tasks) }),
            ("打开笔记多的待办", { switchTab(.tasks); send("openNotedTask") }),
            ("节奏条放大镜", { send("railLoupe") }),
            ("收起放大镜", { send("railLoupeEnd") }),
            ("选择文字", { switchTab(.journal); send("selectText") }),
            ("滑公式不换天", { switchTab(.journal); checkSwipeGuard() }),
            ("点日志编辑", { switchTab(.journal); send("editLog") }),
            ("收起日志编辑", { send("closeLogEditor") }),
            ("滚动全文", { scrollThrough() }),
            ("长按长文", { pressLongText() }),
            ("拖动排序", { switchTab(.tasks); send("dragTask") }),
            ("拖住待办", { switchTab(.tasks); send("dragHold") }),
            ("放下待办", { send("dragEnd") }),
            ("选第一个候选", { send("mentionPick") }),
            ("拖动并放下", { switchTab(.tasks); send("dragDrop") }),
        ]
        // 走两遍：第一遍含第一次建界面的开销，第二遍是平时的样子。`-perfSteps 切到日记,切到待办 -perfRounds 6` 只走其中几步。
        let only = UserDefaults.standard.string(forKey: "perfSteps")?.components(separatedBy: ",")
        let selected = only.map { names in steps.filter { names.contains($0.0) } } ?? steps
        let rounds = max(1, UserDefaults.standard.integer(forKey: "perfRounds"))
        // `-perfStart 8`：第一步晚一点开始（比如等 `-perfTyping` 打完字）。
        let start = UserDefaults.standard.object(forKey: "perfStart") == nil ? 4 : UserDefaults.standard.double(forKey: "perfStart")
        for round in 0..<(UserDefaults.standard.object(forKey: "perfRounds") == nil ? 2 : rounds) {
            for (index, (name, step)) in selected.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + start + Double(round * selected.count + index) * 1.5) {
                    let label = "\(round + 1)·" + name
                    mark(label)
                    pendingAction = (label, CACurrentMediaTime())
                    step()
                }
            }
        }
    }

    /// 在宽公式的滑动条上横着滑不换天，在普通文字上滑照常换天：检查两处的判断。
    static func checkSwipeGuard() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        func strips(_ view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).flatMap { $0.superview is RichTextCanvas ? [$0] : nil } ?? []) + view.subviews.flatMap(strips)
        }
        guard let window = windows.first(where: \.isKeyWindow), let strip = strips(window).first(where: { $0.window != nil }),
              let canvas = strip.superview else { print("[perf] 屏幕上没有宽公式"); return }
        let onStrip = strip.convert(CGPoint(x: strip.bounds.midX, y: strip.bounds.midY), to: nil)
        let onText = canvas.convert(CGPoint(x: 8, y: max(4, strip.frame.minY - 12)), to: nil)
        print("[perf] 公式上横滑：\(HorizontalScrollers.contains(onStrip) ? "不换天" : "会换天") · 文字上横滑：\(HorizontalScrollers.contains(onText) ? "不换天" : "换天")")
    }

    static let typingText = "今天把同步的问题查清楚了 fix the board export when backgrounding 再测一下输入延迟"
    /// `-perfTyping mention`：在记一笔里打 `@` 和 `#` 搜索，候选列表跟着每个字刷新。
    static let mentionText = UserDefaults.standard.string(forKey: "perfTypingText") ?? "@zhengli 今天 #gong 再测一下"

    static func runTyping(switchTab: @escaping (RootView.Tab) -> Void) {
        guard enabled, let typing else { return }
        switchTab(typing == "compose" || typing == "mention" || typing == "log" ? .journal : (typing == "board" ? .boards : .tasks))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            mark("打开输入框 " + typing)
            // 工作板的编辑器在网页里：工作板页自己跑测试（见 BoardWebSession.runTypingTest）。
            NotificationCenter.default.post(name: openEditor, object: typing == "mention" ? "compose" : typing)
        }
        let text: [Character] = Array(typing == "mention" ? mentionText : (UserDefaults.standard.string(forKey: "perfTypingText") ?? typingText))
        if typing == "log" {
            // 日志编辑器也在网页里：打开最长那条的编辑，由编辑卡自己跑测试。
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NotificationCenter.default.post(name: action, object: "editLog") }
            return
        }
        for (index, character) in text.enumerated() where typing != "board" {
            let delay: Double = 6 + Double(index) * 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if index == 0 { mark("开始输入") }
                keyDown = CACurrentMediaTime()
                UIApplication.shared.sendAction(#selector(UIKeyInput.insertText(_:)), to: nil, from: String(character), for: nil)
            }
        }
        let end: Double = 7 + Double(text.count) * 0.1
        if typing != "board" { DispatchQueue.main.asyncAfter(deadline: .now() + end) {
            let sorted: [Double] = latencies.sorted()
            guard let slowest = sorted.last else { print("[perf] 没有输入（没找到输入框）"); return }
            let total: Double = sorted.reduce(0, +)
            let average = total / Double(sorted.count)
            let median = sorted[sorted.count / 2]
            print(String(format: "[perf] 输入 %d 个字：平均 %.1f ms · 中位 %.1f ms · 最慢 %.1f ms", sorted.count, average, median, slowest))
        } }
    }

    /// 自动操作脚本：每一步之间留足时间让上一步的卡顿结束。
    static func runScript(switchTab: @escaping (RootView.Tab) -> Void) {
        guard scripted else { return }
        let calendar = UserDefaults.standard.bool(forKey: "perfCalendar")
        let day = { (offset: Int) in JournalDates.key(JournalDates.calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()) }
        let steps: [(Double, String, () -> Void)] = calendar ? [
            (3, "切到日记", { switchTab(.journal) }),
            (3, "打开日历", { NotificationCenter.default.post(name: openCalendar, object: nil) }),
            (3, "点选日期", { NotificationCenter.default.post(name: pickDay, object: day(-3)) }),
            (3, "再打开日历", { NotificationCenter.default.post(name: openCalendar, object: nil) }),
            (3, "再点选日期", { NotificationCenter.default.post(name: pickDay, object: day(-10)) }),
            (3, "滚到第九条", { NotificationCenter.default.post(name: revealLog, object: 8) }),
            (3, "结束", {}),
        ] : [
            (3, "切到日记", { switchTab(.journal) }),
            (3, "前一天", { NotificationCenter.default.post(name: previousDay, object: nil) }),
            (3, "再前一天", { NotificationCenter.default.post(name: previousDay, object: nil) }),
            (3, "切到待办", { switchTab(.tasks) }),
            (3, "再切到日记", { switchTab(.journal) }),
            (3, "结束", {}),
        ]
        var delay = 0.0
        for (wait, name, action) in steps {
            delay += wait
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { mark(name); action() }
        }
    }
}

extension PerfProbe {
    /// 「滚动全文」：把最上面那个竖向滚动视图（弹出的页面优先）以手指快划的速度滚到底再滚回顶，报这段时间掉了多少帧。
    static func scrollThrough() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if let scroll = view as? UIScrollView, (view as? UITextView)?.isEditable != true, scroll.contentSize.height > scroll.bounds.height * 1.5,
               view.convert(view.bounds, to: window).intersects(window.bounds) { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(window)
        guard let view = found.last else {
            print("[perf] 没找到滚动视图"); return
        }
        scroller = Scroller(view)
    }

    fileprivate static var scroller: Scroller?
    fileprivate static var driver: Driver?

    /// 一帧一帧推着某个动作走 `duration` 秒（`step` 收到 0…1 的进度），报这段时间掉了多少帧。
    static func drive(duration: CFTimeInterval, step: @escaping (CGFloat) -> Void, done: @escaping () -> Void) {
        driver = Driver(duration: duration, step: step, done: done)
    }

    /// 「长按长文」：在屏幕上第一块很长的日志中间弹出长按菜单（模拟器里没法真的长按，用菜单交互测试用的入口）。
    static func pressLongText() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        var anchor: LongTextMenuAnchor?
        func walk(_ view: UIView) {
            if anchor == nil, let found = view as? LongTextMenuAnchor, found.convert(found.bounds, to: window).intersects(window.bounds) { anchor = found }
            view.subviews.forEach(walk)
        }
        walk(window)
        guard let anchor, let scroll = sequence(first: anchor.superview, next: { $0?.superview }).first(where: { $0 is UIScrollView }) as? UIScrollView,
              let interaction = LongTextMenuHub.on(scroll).interaction else { print("[perf] 屏幕上没有很长的日志"); return }
        let shown = anchor.convert(anchor.bounds, to: scroll).intersection(scroll.bounds)
        let selector = NSSelectorFromString("_presentMenuAtLocation:")
        guard let method = class_getInstanceMethod(UIContextMenuInteraction.self, selector) else { print("[perf] 没有菜单测试入口"); return }
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        unsafeBitCast(method_getImplementation(method), to: Present.self)(interaction, selector, CGPoint(x: shown.midX, y: shown.midY))
    }
}

private final class Driver: NSObject {
    private let duration: CFTimeInterval
    private let step: (CGFloat) -> Void
    private let done: () -> Void
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var slow = 0
    private var worst: CFTimeInterval = 0
    private var interval: CFTimeInterval = 1 / 60

    init(duration: CFTimeInterval, step: @escaping (CGFloat) -> Void, done: @escaping () -> Void) {
        self.duration = duration
        self.step = step
        self.done = done
        super.init()
        link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { start = link.timestamp; interval = link.targetTimestamp - link.timestamp; return }
        let gap = link.timestamp - last
        frames += 1
        if gap > interval * 1.5 { slow += 1 }
        worst = max(worst, gap)
        let progress = min(1, (link.timestamp - start) / duration)
        MainActor.assumeIsolated { step(progress) }
        guard progress >= 1 else { return }
        link.invalidate()
        MainActor.assumeIsolated { done() }
        print(String(format: "[perf] 推动 %.1f 秒：%d 帧，掉帧 %d 帧，最长一帧 %.0f ms", duration, frames, slow, worst * 1000))
    }
}

/// 用显示链接一帧一帧推着滚：每秒 2500 点，下去再上来。
private final class Scroller: NSObject {
    private let view: UIScrollView
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var down = true
    private var frames = 0
    private var slow = 0
    private var worst: CFTimeInterval = 0
    private var interval: CFTimeInterval = 1 / 60

    init(_ view: UIScrollView) {
        self.view = view
        super.init()
        view.setContentOffset(CGPoint(x: 0, y: -view.adjustedContentInset.top), animated: false)
        MainActor.assumeIsolated {
            PerfProbe.typesetting = 0
            PerfProbe.drawing = 0
        }
        link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link?.add(to: .main, forMode: .common)
        print("[perf] 开始滚动：内容高 \(Int(view.contentSize.height))")
    }

    @objc private func step(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { interval = link.targetTimestamp - link.timestamp; return }
        let gap = link.timestamp - last
        frames += 1
        if gap > interval * 1.5 {
            slow += 1
            print(String(format: "[perf]   第 %d 帧掉帧 %.0f ms（滚到 %d）", frames, gap * 1000, Int(view.contentOffset.y)))
        }
        worst = max(worst, gap)
        let top = -view.adjustedContentInset.top
        let bottom = view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom
        var y = view.contentOffset.y + (down ? 1 : -1) * 2500 * gap
        if down, y >= bottom { y = bottom; down = false }
        if !down, y <= top {
            y = top
            link.invalidate()
            print(String(format: "[perf] 滚动全文：%d 帧，掉帧 %d 帧，最长一帧 %.0f ms，内容高 %d；主线程排正文 %.1f ms，画正文 %.1f ms",
                         frames, slow, worst * 1000, Int(view.contentSize.height),
                         MainActor.assumeIsolated { PerfProbe.typesetting } * 1000, MainActor.assumeIsolated { PerfProbe.drawing } * 1000))
        }
        view.contentOffset.y = y
    }
}

private final class FrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    override init() {
        super.init()
        link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func frame(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        MainActor.assumeIsolated { PerfProbe.frameDrawn(at: CACurrentMediaTime()) }
        guard last > 0 else { return }
        let gap = link.timestamp - last
        if gap > 0.034 { MainActor.assumeIsolated { PerfProbe.hitch(Int(gap * 1000)) } }
    }
}
