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

    static func start() {
        guard enabled, monitor == nil else { return }
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

    private static var typesetting: CFTimeInterval = 0
    private static var drawing: CFTimeInterval = 0

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
            ("打开待办笔记页", { send("openTask") }),
            ("任务设置", { send("editTask") }),
            ("关掉任务设置", { send("closeSheet") }),
            ("返回待办", { send("popTask") }),
            ("新建待办", { send("addTask") }),
            ("关掉新建待办", { send("closeSheet") }),
            ("切到日记", { switchTab(.journal) }),
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
        ]
        // 走两遍：第一遍含第一次建界面的开销，第二遍是平时的样子。`-perfSteps 切到日记,切到待办 -perfRounds 6` 只走其中几步。
        let only = UserDefaults.standard.string(forKey: "perfSteps")?.components(separatedBy: ",")
        let selected = only.map { names in steps.filter { names.contains($0.0) } } ?? steps
        let rounds = max(1, UserDefaults.standard.integer(forKey: "perfRounds"))
        for round in 0..<(UserDefaults.standard.object(forKey: "perfRounds") == nil ? 2 : rounds) {
            for (index, (name, step)) in selected.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4 + Double(round * selected.count + index) * 1.5) {
                    let label = "\(round + 1)·" + name
                    mark(label)
                    pendingAction = (label, CACurrentMediaTime())
                    step()
                }
            }
        }
    }

    static let typingText = "今天把同步的问题查清楚了 fix the board export when backgrounding 再测一下输入延迟"

    static func runTyping(switchTab: @escaping (RootView.Tab) -> Void) {
        guard enabled, let typing else { return }
        switchTab(typing == "compose" ? .journal : (typing == "board" ? .boards : .tasks))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            mark("打开输入框 " + typing)
            // 工作板的编辑器在网页里：工作板页自己跑测试（见 BoardWebSession.runTypingTest）。
            NotificationCenter.default.post(name: openEditor, object: typing)
        }
        let text: [Character] = Array(typingText)
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
