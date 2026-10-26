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

    private static var parsing: CFTimeInterval = 0

    /// 主线程上现解析 Markdown 花的时间，卡顿时一起报出来。
    static func parsed(_ seconds: CFTimeInterval) { if enabled { parsing += seconds } }

    fileprivate static func hitch(_ milliseconds: Int) {
        if parsing > 0.001 { print("[perf]   其中主线程解析 Markdown \(Int(parsing * 1000)) ms") }
        parsing = 0
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
        guard let start = keyDown else { return }
        latencies.append((time - start) * 1000)
        keyDown = nil
    }

    static func runTyping(switchTab: @escaping (RootView.Tab) -> Void) {
        guard enabled, let typing else { return }
        switchTab(typing == "compose" ? .journal : (typing == "board" ? .boards : .tasks))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            mark("打开输入框 " + typing)
            NotificationCenter.default.post(name: openEditor, object: typing)
        }
        let text: [Character] = Array("今天把同步的问题查清楚了 fix the board export when backgrounding 再测一下输入延迟")
        for (index, character) in text.enumerated() {
            let delay: Double = 6 + Double(index) * 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if index == 0 { mark("开始输入") }
                keyDown = CACurrentMediaTime()
                UIApplication.shared.sendAction(#selector(UIKeyInput.insertText(_:)), to: nil, from: String(character), for: nil)
            }
        }
        let end: Double = 7 + Double(text.count) * 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + end) {
            let sorted: [Double] = latencies.sorted()
            guard let slowest = sorted.last else { print("[perf] 没有输入（没找到输入框）"); return }
            let total: Double = sorted.reduce(0, +)
            let average = total / Double(sorted.count)
            let median = sorted[sorted.count / 2]
            print(String(format: "[perf] 输入 %d 个字：平均 %.1f ms · 中位 %.1f ms · 最慢 %.1f ms", sorted.count, average, median, slowest))
        }
    }

    /// 自动操作脚本：每一步之间留足时间让上一步的卡顿结束。
    static func runScript(switchTab: @escaping (RootView.Tab) -> Void) {
        guard scripted else { return }
        let steps: [(Double, String, () -> Void)] = [
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
