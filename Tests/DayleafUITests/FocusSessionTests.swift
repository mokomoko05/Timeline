import AppKit
import SwiftUI
import XCTest
import DayleafCore
@testable import Dayleaf

@MainActor
final class FocusSessionTests: XCTestCase {
    private func makeSession() throws -> (FocusSession, JournalStore, ScheduledTask) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        store.addTodo("看回放 [课程](https://v.example.edu/play-center?id=1#/room)", on: Date())
        let task = try XCTUnwrap(store.locate(number: 1))
        let session = FocusSession()
        session.store = store
        session.openLink = { _ in }
        session.activateExistingTab = { _ in false }
        // 夹具里的专注大多是瞬间结束的：默认每次都记，阈值另有专门的测试。
        session.minLoggedSeconds = { 0 }
        return (session, store, task)
    }

    private func result(onTarget: Bool, reason: String = "离开了目标页面", page: String? = nil) -> FocusProbe.Result {
        FocusProbe.Result(onTarget: onTarget, awayReason: reason, frontBundle: "com.apple.Safari", pageURL: page.flatMap(URL.init(string:)), automationDenied: false)
    }

    func testOnlyTasksWithAWebOrFileLinkOfferFocus() {
        XCTAssertEqual(FocusSession.link(in: "看 [课程](https://a.edu/x)")?.host, "a.edu")
        XCTAssertEqual(FocusSession.link(in: "读 https://arxiv.org/pdf/2609.27396")?.host, "arxiv.org")
        XCTAssertEqual(FocusSession.link(in: "读 [pdf](file:///Users/me/a.pdf)")?.path, "/Users/me/a.pdf")
        XCTAssertNil(FocusSession.link(in: "买牛奶"))
        XCTAssertNil(FocusSession.link(in: "[邮件](mailto:a@b.c)"))
    }

    func testPageMatchingIgnoresQueryFragmentWwwAndTrailingSlash() throws {
        let base = FocusSession.baseline(for: try XCTUnwrap(URL(string: "https://www.v.example.edu/play-center/?id=1#/room")))
        XCTAssertTrue(FocusSession.matches(try XCTUnwrap(URL(string: "https://v.example.edu/play-center?id=2#/other")), base))
        XCTAssertFalse(FocusSession.matches(try XCTUnwrap(URL(string: "https://v.example.edu/other")), base))
        XCTAssertFalse(FocusSession.matches(try XCTUnwrap(URL(string: "https://news.example.com/play-center")), base))
    }

    func testFindsTheAlreadyOpenTabAcrossWindowsIgnoringQueryAndFragment() throws {
        let target = try XCTUnwrap(URL(string: "https://v.example.edu/play-center?id=1#/room"))
        let output = "11\t1\thttps://news.example.com/\n11\t2\thttps://www.google.com/search?q=x\n42\t1\thttps://v.example.edu/\n42\t3\thttps://v.example.edu/play-center/?id=9#/other\n"
        let found = try XCTUnwrap(FocusProbe.bestTab(in: output, for: target))
        XCTAssertEqual(found.window, 42)
        XCTAssertEqual(found.tab, 3)
        XCTAssertNil(FocusProbe.bestTab(in: "11\t1\thttps://news.example.com/\n", for: target))
        XCTAssertNil(FocusProbe.bestTab(in: "", for: target))
        let pdf = try XCTUnwrap(URL(string: "file:///Users/me/Reading/paper.pdf"))
        XCTAssertEqual(FocusProbe.bestTab(in: "7\t2\tfile:///Users/me/Reading/paper.pdf\n", for: pdf)?.tab, 2)
    }

    func testAlreadyOpenPageIsActivatedInsteadOfReloaded() async throws {
        let (session, _, task) = try makeSession()
        var opened = 0
        var activated = 0
        session.openLink = { _ in opened += 1 }
        session.activateExistingTab = { _ in activated += 1; return true }
        session.start(task: task, url: try XCTUnwrap(FocusSession.link(in: task.task.title)))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(activated, 1)
        XCTAssertEqual(opened, 0, "页面已经开着时不再重新打开，避免回到页面开头")
        session.stop(reason: "手动结束")
        session.activateExistingTab = { _ in false }
        session.start(task: task, url: try XCTUnwrap(FocusSession.link(in: task.task.title)))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(opened, 1, "没开着才打开链接")
        session.stop(reason: "手动结束")
    }

    func testOrdinaryLinkClicksAlsoReuseAnOpenTab() async throws {
        let (activate, launch) = (SafariLinks.activateExistingTab, SafariLinks.launch)
        defer { SafariLinks.activateExistingTab = activate; SafariLinks.launch = launch }
        var launched: [URL] = []
        SafariLinks.launch = { launched.append($0) }
        SafariLinks.activateExistingTab = { _ in true }
        SafariLinks.open(try XCTUnwrap(URL(string: "https://arxiv.org/pdf/2609.27396")))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(launched.isEmpty, "已开着的页面直接切换，不再重新打开")
        SafariLinks.activateExistingTab = { _ in false }
        SafariLinks.open(try XCTUnwrap(URL(string: "https://arxiv.org/pdf/2609.27396")))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(launched.map(\.host), ["arxiv.org"], "没开着才打开")
    }

    /// 专注的任务被完成、放弃或删除：计时立刻结束，写明原因，不再往已关闭的任务上累加。
    func testClosingTheFocusedTaskStopsTheTimerWithAReason() async throws {
        for (close, reason) in [("完成", "任务已完成"), ("放弃", "任务已放弃"), ("删除", "任务已删除")] {
            let (session, store, task) = try makeSession()
            let start = Date().addingTimeInterval(-2)
            session.start(task: task, url: try XCTUnwrap(FocusSession.link(in: task.task.title)), now: start)
            switch close {
            case "完成": store.toggleTodo(task.id, on: task.date)
            case "放弃": store.dropTodo(task.id, on: task.date)
            default: store.deleteTodo(task.id, on: task.date)
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertNil(session.active, "\(close)后专注自动结束")
            XCTAssertNil(store.focusTaskID)
            let last = store.allLogs(includeFocus: true).last?.log.text ?? ""
            XCTAssertTrue(last.contains(reason), "结束原因写明了：\(last)")
        }
    }

    func testEditingTheFocusedTaskDoesNotStopTheTimer() async throws {
        let (session, store, task) = try makeSession()
        session.start(task: task, url: try XCTUnwrap(FocusSession.link(in: task.task.title)))
        store.renameTodo(task.id, title: "改了名字 [课程](https://v.example.edu/play-center)", on: task.date)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotNil(session.active, "只是改名、加标签不会结束")
        session.stop(reason: "手动结束")
    }

    /// 没有链接的待办：和有链接的一样能专注计时，只是不打开页面、不检测窗口。
    func testTaskWithoutALinkCanFocusButOpensNothingAndNeverAutoStops() async throws {
        let (session, store, _) = try makeSession()
        store.addTodo("整理房间", on: Date())
        let plain = try XCTUnwrap(store.locate(number: 2))
        XCTAssertNil(FocusSession.link(in: plain.task.title))
        var opened: [URL] = []
        session.openLink = { opened.append($0) }
        var probed = 0
        session.activateExistingTab = { _ in probed += 1; return false }
        let start = Date()
        var changes: [Bool] = []
        session.onActiveChange = { changes.append($0) }

        session.start(task: plain, url: nil, now: start)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(session.active)
        XCTAssertNil(session.active?.url)
        XCTAssertEqual(changes, [true], "计时窗口照常出现")
        XCTAssertTrue(opened.isEmpty, "没有链接，不打开任何页面")
        XCTAssertEqual(probed, 0, "也不去找已经开着的标签页")
        XCTAssertEqual(store.focusTaskID, plain.id, "专注期间的日志照常关联到它")

        // 不检测：计时器每秒走一次，但没有链接就不会去探测前台，所以不会因为「离开」而自动结束。
        // 使用真实当前时间，避免上午运行时开始时间落在未来。
        try? await Task.sleep(nanoseconds: 2_300_000_000)
        XCTAssertNotNil(session.active, "没有链接的专注只能手动结束")
        XCTAssertGreaterThan(session.elapsed, 0.5, "秒表照常走")

        session.stop(reason: "手动结束", now: start.addingTimeInterval(1503))
        XCTAssertEqual(changes, [true, false])
        let logs = try XCTUnwrap(store.days[JournalDates.key(start)]?.logs)
        XCTAssertEqual(logs.map(\.text), ["▶ 开始专注", "■ 结束专注 · 用时 25 分 3 秒 · 累计 25 分 3 秒 · 手动结束"], "日志和有链接的任务完全一样")
        XCTAssertEqual(store.locate(plain.id)?.task.focusSeconds ?? 0, 1503, accuracy: 0.01)
    }

    func testSwitchingBetweenLinkedAndPlainTasksEndsTheFirst() throws {
        let (session, store, linked) = try makeSession()
        store.addTodo("整理房间", on: Date())
        let plain = try XCTUnwrap(store.locate(number: 2))
        session.start(task: linked, url: try XCTUnwrap(FocusSession.link(in: linked.task.title)))
        session.start(task: plain, url: nil)
        XCTAssertEqual(session.active?.taskID, plain.id, "切到没有链接的任务，前一个正常结束")
        XCTAssertEqual(store.locate(linked.id)?.task.focusSeconds ?? -1, 0, accuracy: 1)
        session.stop(reason: "手动结束")
        XCTAssertNil(session.active)
    }

    func testStartLogsStartTimeAndStopLogsDurationAndReason() async throws {
        let (session, store, task) = try makeSession()
        var opened: [URL] = []
        session.openLink = { opened.append($0) }
        // 固定在中午：深夜运行时 25 分钟后会跨过午夜，结束记录就落到第二天了。
        let start = JournalDates.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        session.start(task: task, url: try XCTUnwrap(FocusSession.link(in: task.task.title)), now: start)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(opened.first?.host, "v.example.edu")
        XCTAssertEqual(session.active?.number, 1)
        session.stop(reason: "手动结束", now: start.addingTimeInterval(1503))
        XCTAssertNil(session.active)
        let logs = try XCTUnwrap(store.days[JournalDates.key(start)]?.logs)
        XCTAssertEqual(logs.map(\.text), ["▶ 开始专注", "■ 结束专注 · 用时 25 分 3 秒 · 累计 25 分 3 秒 · 手动结束"])
        XCTAssertEqual(store.locate(task.id)?.task.focusSeconds ?? 0, 1503, accuracy: 0.01, "用时累加到任务上")
        XCTAssertEqual(logs.map(\.createdAt), [start, start.addingTimeInterval(1503)])
        XCTAssertTrue(logs.allSatisfy { $0.focus && $0.taskID == task.id })
        XCTAssertEqual(store.notes(for: task.id).map { $0.log.focusMarker }, ["FOCUS", "END"])
    }

    func testFocusShorterThanTheThresholdLeavesNoLogButStillCountsTheTime() async throws {
        let (session, store, task) = try makeSession()
        session.minLoggedSeconds = { 300 }
        let start = JournalDates.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let url = try XCTUnwrap(FocusSession.link(in: task.task.title))
        session.start(task: task, url: url, now: start)
        XCTAssertEqual(store.days[JournalDates.key(start)]?.logs.count, 1, "进行中能看到「开始专注」")
        session.stop(reason: "手动结束", now: start.addingTimeInterval(299))
        XCTAssertNil(session.active)
        XCTAssertEqual(store.days[JournalDates.key(start)]?.logs.count, 0, "不足 5 分钟：开始那条也撤掉，当天没有任何日志")
        XCTAssertEqual(store.locate(task.id)?.task.focusSeconds ?? 0, 299, accuracy: 0.01, "时间仍累加到任务上")
        XCTAssertNil(store.focusTask, "专注状态已清除")
        store.undoManager.undo()
        XCTAssertEqual(store.days[JournalDates.key(start)]?.logs.count, 1, "⌘Z 一起还原")

        // 刚好到阈值：正常记录开始和结束。
        session.start(task: task, url: url, now: start.addingTimeInterval(1000))
        session.stop(reason: "手动结束", now: start.addingTimeInterval(1300))
        let logs = try XCTUnwrap(store.days[JournalDates.key(start)]?.logs)
        XCTAssertTrue(logs.last?.text.hasPrefix("■ 结束专注 · 用时 5 分 0 秒") == true, logs.map(\.text).joined(separator: " | "))
    }

    func testThresholdOfZeroAlwaysLogsAndOtherLogsOfTheDayAreUntouched() throws {
        let (session, store, task) = try makeSession()
        let start = JournalDates.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        _ = try store.quickLog("当天的普通日志", on: start, now: start.addingTimeInterval(-60))
        let url = try XCTUnwrap(FocusSession.link(in: task.task.title))
        session.start(task: task, url: url, now: start)
        session.stop(reason: "手动结束", now: start.addingTimeInterval(2))
        XCTAssertEqual(store.days[JournalDates.key(start)]?.logs.map(\.text).count, 3, "阈值 0：再短也记")
        session.minLoggedSeconds = { 300 }
        session.start(task: task, url: url, now: start.addingTimeInterval(100))
        session.stop(reason: "手动结束", now: start.addingTimeInterval(110))
        XCTAssertEqual(store.days[JournalDates.key(start)]?.logs.count, 3, "太短的那次不增加日志，也不会误删别的日志")
        XCTAssertEqual(store.days[JournalDates.key(start)]?.logs.first?.text, "当天的普通日志")
    }

    func testDefaultThresholdIsFiveMinutesAndReadsThePreference() {
        let key = Prefs.focusMinLogMinutes
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Prefs.focusMinLogSeconds, 300, "默认 5 分钟")
        UserDefaults.standard.set(12, forKey: key)
        XCTAssertEqual(Prefs.focusMinLogSeconds, 720)
        UserDefaults.standard.set(0, forKey: key)
        XCTAssertEqual(Prefs.focusMinLogSeconds, 0, "0 表示都记")
        UserDefaults.standard.set(-3, forKey: key)
        XCTAssertEqual(Prefs.focusMinLogSeconds, 0, "负数当 0")
    }

    func testDefaultFocusDurationPersistsAndExplicitSessionDurationOverridesIt() throws {
        let key = Prefs.focusDefaultMinutes
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Prefs.focusDurationMinutes(), 25)
        UserDefaults.standard.set(45, forKey: key)
        XCTAssertEqual(Prefs.focusDurationMinutes(), 45)
        let (session, _, task) = try makeSession()
        session.start(task: task, url: nil)
        XCTAssertEqual(session.active?.plannedSeconds, 45 * 60)
        session.stop(reason: "test")
        session.start(task: task, url: nil, plannedSeconds: 10 * 60)
        XCTAssertEqual(session.active?.plannedSeconds, 10 * 60)
        XCTAssertEqual(Prefs.focusDurationMinutes(), 45, "单轮调整不覆盖设置里的默认时长")
        session.stop(reason: "test")
        UserDefaults.standard.set(0, forKey: key)
        XCTAssertEqual(Prefs.focusDurationMinutes(), 25)
    }

    func testManualMinuteSettingsValidateWholeMinutesAndAllowZeroOnlyForLogThreshold() {
        XCTAssertEqual(FocusMinutesSetting.validMinutes(" 45 ", minimum: 1), 45)
        XCTAssertEqual(FocusMinutesSetting.validMinutes("180", minimum: 0), 180)
        XCTAssertEqual(FocusMinutesSetting.validMinutes("0", minimum: 0), 0)
        for text in ["", "-1", "1.5", "abc", "99999999999999999999999"] {
            XCTAssertNil(FocusMinutesSetting.validMinutes(text, minimum: 0))
        }
        XCTAssertNil(FocusMinutesSetting.validMinutes("0", minimum: 1))
    }

    func testLeavingNeedsConsecutivePollsAndGraceAdoptsRedirectedPage() throws {
        let (session, store, task) = try makeSession()
        session.start(task: task, url: try XCTUnwrap(FocusSession.link(in: task.task.title)))
        // 宽限期内即使不在目标页面也不结束，并把实际打开的页面（重定向后）当作目标。
        session.apply(result(onTarget: false, page: "https://sso.example.edu/landing"), inGrace: true)
        XCTAssertNotNil(session.active)
        session.apply(result(onTarget: true), inGrace: false)
        session.apply(result(onTarget: false), inGrace: false)
        XCTAssertNotNil(session.active, "只离开一次不算，避免通知或 Spotlight 一闪而过")
        session.apply(result(onTarget: true), inGrace: false)
        session.apply(result(onTarget: false), inGrace: false)
        XCTAssertNotNil(session.active, "中间回到页面会重新计数")
        session.apply(result(onTarget: false, reason: "切换到了微信"), inGrace: false)
        XCTAssertNil(session.active)
        let last = try XCTUnwrap(store.days.values.flatMap(\.logs).max { $0.createdAt < $1.createdAt })
        XCTAssertTrue(last.text.hasPrefix("■ 结束专注"))
        XCTAssertTrue(last.text.hasSuffix("切换到了微信"))
    }

    func testWorkingInDayleafItselfNeverCountsAsLeavingAndKeepsAccumulating() throws {
        let (session, store, task) = try makeSession()
        session.start(task: task, url: try XCTUnwrap(FocusSession.link(in: task.task.title)))
        var own = result(onTarget: true)
        own.ownApp = true
        for _ in 0..<30 { session.apply(own, inGrace: false) }
        XCTAssertNotNil(session.active, "在 Scheduler 里记笔记不会停止计时")
        // Scheduler 前台期间的计数清零：回到浏览器后只离开一次不会立刻结束。
        session.apply(result(onTarget: false), inGrace: false)
        session.apply(own, inGrace: false)
        session.apply(result(onTarget: false), inGrace: false)
        XCTAssertNotNil(session.active)
        session.apply(result(onTarget: false), inGrace: false)
        XCTAssertNil(session.active, "回到浏览器后不在目标页面，照常判定离开")
        _ = store
    }

    func testDegradedDetectionIsReportedOncePerSession() throws {
        let (session, _, task) = try makeSession()
        var warnings = 0
        session.onDegraded = { warnings += 1 }
        session.start(task: task, url: try XCTUnwrap(FocusSession.link(in: task.task.title)))
        var denied = result(onTarget: true)
        denied.automationDenied = true
        for _ in 0..<5 { session.apply(denied, inGrace: false) }
        XCTAssertEqual(warnings, 1)
    }

    func testStartingAnotherTaskEndsTheFirstOne() throws {
        let (session, store, first) = try makeSession()
        store.addTodo("另一个 [页面](https://b.example.com/x)", on: Date())
        let second = try XCTUnwrap(store.locate(number: 2))
        session.start(task: first, url: try XCTUnwrap(FocusSession.link(in: first.task.title)))
        session.start(task: second, url: try XCTUnwrap(FocusSession.link(in: second.task.title)))
        XCTAssertEqual(session.active?.taskID, second.id)
        let texts = store.days.values.flatMap(\.logs).map(\.text)
        XCTAssertTrue(texts.contains { $0.contains("切换到了另一个任务") })
    }

    func testSessionsAccumulateOnTheTaskAndShowRunningTotal() throws {
        let (session, store, task) = try makeSession()
        let url = try XCTUnwrap(FocusSession.link(in: task.task.title))
        let t0 = Date()
        session.start(task: task, url: url, now: t0)
        session.stop(reason: "手动结束", now: t0.addingTimeInterval(600))
        session.start(task: task, url: url, now: t0.addingTimeInterval(1000))
        session.stop(reason: "离开了目标页面", now: t0.addingTimeInterval(1900))
        XCTAssertEqual(store.locate(task.id)?.task.focusSeconds ?? 0, 1500, accuracy: 0.01)
        let ends = store.days.values.flatMap(\.logs).filter { $0.text.hasPrefix("■") }.sorted { $0.createdAt < $1.createdAt }
        XCTAssertTrue(ends[1].text.contains("用时 15 分 0 秒 · 累计 25 分 0 秒"))
        XCTAssertEqual(FocusSession.brief(5000), "1 小时 23 分")
        XCTAssertEqual(FocusSession.brief(1500), "25 分钟")
        XCTAssertEqual(FocusSession.brief(40), "40 秒")
    }

    func testPausingFreezesElapsedUntilResumed() throws {
        let (session, store, task) = try makeSession()
        let start = JournalDates.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        session.start(task: task, url: nil, now: start)
        session.pause(now: start.addingTimeInterval(120))
        XCTAssertTrue(session.isPaused)
        XCTAssertEqual(session.elapsed, 120, accuracy: 0.01)
        session.pause(now: start.addingTimeInterval(180))
        XCTAssertEqual(session.elapsed, 120, accuracy: 0.01, "重复暂停不会改变已用时间")
        session.resume(now: start.addingTimeInterval(300))
        XCTAssertFalse(session.isPaused)
        XCTAssertEqual(session.elapsed, 120, accuracy: 0.01, "恢复时扣除暂停的 3 分钟")
        session.stop(reason: "手动结束", now: start.addingTimeInterval(360))
        XCTAssertEqual(store.locate(task.id)?.task.focusSeconds ?? 0, 180, accuracy: 0.01)
    }

    func testGoalPlanAndEffectiveDurationAreSavedAsTypedEvents() throws {
        let (session, store, task) = try makeSession()
        let start = Date()
        session.start(task: task, url: nil, plannedSeconds: 1500, goal: "  Read **methods**\nCompare assumptions  ", now: start)
        let log = try XCTUnwrap(store.allLogs(includeFocus: true).first?.log)
        XCTAssertEqual(log.focusEvent, .start)
        XCTAssertEqual(log.focusGoal, "Read **methods**\nCompare assumptions")
        XCTAssertEqual(log.focusPlannedSeconds, 1500)
        session.pause(now: start.addingTimeInterval(60))
        session.stop(reason: "手动结束", now: start.addingTimeInterval(300))
        let end = try XCTUnwrap(store.allLogs(includeFocus: true).last?.log)
        XCTAssertEqual(end.focusEvent, .end)
        XCTAssertEqual(end.focusElapsedSeconds, 60)
        XCTAssertEqual(end.focusEndReason, "手动结束")
        store.save()
        let reloaded = JournalStore(directory: store.directory)
        XCTAssertEqual(reloaded.notes(for: task.id).first?.log.focusGoal, log.focusGoal)
    }

    func testShortSessionKeepsAnExplicitGoalEvenBelowLoggingThreshold() throws {
        let (session, store, task) = try makeSession()
        session.minLoggedSeconds = { 300 }
        let now = Date()
        session.start(task: task, url: nil, goal: "Keep this goal", now: now)
        session.stop(reason: "手动结束", now: now.addingTimeInterval(30))
        XCTAssertEqual(store.notes(for: task.id).map { $0.log.focusMarker }, ["FOCUS", "END"])
        XCTAssertEqual(store.notes(for: task.id).first?.log.focusGoal, "Keep this goal")
        XCTAssertEqual(store.locate(task.id)?.task.focusSeconds, 30)
    }

    func testCountdownRequestsReflectionOnceAndDoesNotCountTimeSpentReflecting() throws {
        let (session, store, task) = try makeSession()
        let start = Date()
        var prompts = 0
        session.onCountdownEnd = { prompts += 1 }
        session.start(task: task, url: nil, plannedSeconds: 60, now: start)
        session.tick(now: start.addingTimeInterval(59))
        XCTAssertFalse(session.needsReflection)
        session.tick(now: start.addingTimeInterval(90))
        XCTAssertTrue(session.needsReflection)
        XCTAssertTrue(session.isPaused)
        XCTAssertEqual(session.elapsed, 60)
        session.tick(now: start.addingTimeInterval(600))
        XCTAssertEqual(prompts, 1)
        session.resume(now: start.addingTimeInterval(600))
        XCTAssertTrue(session.isPaused)
        session.stop(reason: "计时结束", now: start.addingTimeInterval(600))
        XCTAssertEqual(store.locate(task.id)?.task.focusSeconds, 60)
        XCTAssertFalse(session.needsReflection)
    }

    func testExtensionAfterCountdownResumesAndPromptsAtTheNextEnd() throws {
        let (session, _, task) = try makeSession()
        let start = Date()
        session.start(task: task, url: nil, plannedSeconds: 60, now: start)
        session.pause(now: start.addingTimeInterval(30))
        session.tick(now: start.addingTimeInterval(600))
        XCTAssertFalse(session.needsReflection)
        session.resume(now: start.addingTimeInterval(600))
        session.tick(now: start.addingTimeInterval(630))
        XCTAssertTrue(session.needsReflection)
        session.extend(by: 300, now: start.addingTimeInterval(700))
        XCTAssertFalse(session.isPaused)
        XCTAssertFalse(session.needsReflection)
        XCTAssertEqual(session.remainingSeconds, 300)
        session.tick(now: start.addingTimeInterval(1000))
        XCTAssertTrue(session.needsReflection)
        XCTAssertEqual(session.elapsed, 360)
        session.stop(reason: "test", now: start.addingTimeInterval(1000))
    }

    func testCountdownDialAndDigitsStayInSyncAcrossPauseExtensionAndOvertime() throws {
        let (session, _, task) = try makeSession()
        let start = Date()
        XCTAssertEqual(session.remainingFraction, 0)
        session.start(task: task, url: nil, plannedSeconds: 1500, now: start)
        XCTAssertEqual(session.remainingFraction, 1)
        session.pause(now: start.addingTimeInterval(600))
        XCTAssertEqual(FocusSession.clock(session.remainingSeconds), "15:00")
        XCTAssertEqual(session.remainingFraction, 0.6, accuracy: 0.001)
        session.pause(now: start.addingTimeInterval(900))
        XCTAssertEqual(session.remainingSeconds, 900)
        session.extend(by: 300)
        XCTAssertEqual(FocusSession.clock(session.remainingSeconds), "20:00")
        XCTAssertEqual(session.remainingFraction, 2.0 / 3, accuracy: 0.001)
        session.resume(now: start.addingTimeInterval(900))
        XCTAssertEqual(session.remainingSeconds, 1200)
        session.pause(now: start.addingTimeInterval(2400))
        XCTAssertEqual(FocusSession.clock(session.remainingSeconds), "00:00")
        XCTAssertEqual(session.remainingFraction, 0)
        XCTAssertNotNil(session.active, "到点后仍由用户结束专注")
        session.stop(reason: "test", now: start.addingTimeInterval(2400))
        XCTAssertEqual(session.remainingSeconds, 0)
        XCTAssertEqual(session.remainingFraction, 0)
    }

    func testStoppingWhilePausedExcludesThePausedTime() throws {
        let (session, store, task) = try makeSession()
        let start = JournalDates.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        session.start(task: task, url: nil, now: start)
        session.pause(now: start.addingTimeInterval(90))
        session.stop(reason: "手动结束", now: start.addingTimeInterval(600))
        XCTAssertFalse(session.isPaused)
        XCTAssertEqual(store.locate(task.id)?.task.focusSeconds ?? 0, 90, accuracy: 0.01)
    }

    func testQuickLogsDuringFocusLinkToTheFocusedTaskAndStopWhenItEnds() throws {
        let (session, store, task) = try makeSession()
        let day = Date()
        store.addTodo("另一件事", on: day)
        let other = try XCTUnwrap(store.locate(number: 2))

        _ = try store.quickLog("开始前", on: day)
        session.start(task: task, url: try XCTUnwrap(URL(string: "https://v.example.edu/play-center")))
        XCTAssertEqual(store.focusTaskID, task.id)

        _ = try store.quickLog("第二页的公式很关键", on: day)
        _ = try store.quickLog("/done 看完一半", on: day)
        _ = try store.quickLog("手动指定", taskID: other.id, on: day)

        let focusedLogs = store.entry(for: day).logs.filter { !$0.focus }
        XCTAssertNil(focusedLogs.first { $0.text == "开始前" }?.taskID)
        XCTAssertEqual(focusedLogs.first { $0.text == "第二页的公式很关键" }?.taskID, task.id)
        XCTAssertEqual(focusedLogs.first { $0.text == "第二页的公式很关键" }?.taskNumber, 1)
        XCTAssertEqual(focusedLogs.first { $0.text == "看完一半" }?.taskID, task.id)
        XCTAssertEqual(focusedLogs.first { $0.text == "手动指定" }?.taskID, other.id, "明确指定的任务优先于专注任务")
        XCTAssertFalse(try XCTUnwrap(store.locate(task.id)).task.completed, "快速日志里的 /done 不会替用户完成任务")
        XCTAssertEqual(store.notes(for: task.id).map(\.log.text), ["▶ 开始专注", "第二页的公式很关键", "看完一半"], "笔记视图完整展示本轮专注流水")

        session.stop(reason: "手动结束")
        XCTAssertNil(store.focusTaskID)
        _ = try store.quickLog("结束后", on: day)
        XCTAssertNil(store.entry(for: day).logs.last?.taskID)
    }

    func testMainWindowLogInputAlsoLinksToTheFocusedTaskButExplicitChoiceWins() throws {
        let (session, store, task) = try makeSession()
        let day = Date()
        store.addTodo("另一件事", on: day)
        let other = try XCTUnwrap(store.locate(number: 2))
        session.start(task: task, url: try XCTUnwrap(URL(string: "https://v.example.edu/play-center")))

        store.setLogDraft("读到第三节", on: day)
        try store.commitLog(on: day)
        store.setLogDraft("#2 顺手记一下", on: day)
        try store.commitLog(on: day)
        store.setLogTask(other.id, on: day)
        store.setLogDraft("选了任务的", on: day)
        try store.commitLog(on: day)
        store.setLogDraft("/done", on: day)
        XCTAssertThrowsError(try store.commitLog(on: day), "专注兜底的关联不借用标题，空的 /done 仍然报空")

        let logs = store.entry(for: day).logs.filter { !$0.focus }
        XCTAssertEqual(logs.map(\.taskID), [task.id, other.id, other.id])
        XCTAssertEqual(logs.first?.text, "读到第三节")
        XCTAssertFalse(try XCTUnwrap(store.locate(task.id)).task.completed)
    }

    func testDeletingTheFocusedTaskDegradesToUnlinkedLogs() throws {
        let (session, store, task) = try makeSession()
        let day = Date()
        session.start(task: task, url: try XCTUnwrap(URL(string: "https://v.example.edu/play-center")))
        store.deleteTodo(task.id, on: task.date)
        XCTAssertNil(store.focusTask)
        _ = try store.quickLog("任务没了", on: day)
        XCTAssertNil(store.entry(for: day).logs.last { !$0.focus }?.taskID)
    }

    func testDurationFormatting() {
        XCTAssertEqual(FocusSession.duration(59), "59 秒")
        XCTAssertEqual(FocusSession.duration(3725), "1 小时 2 分 5 秒")
        XCTAssertEqual(FocusSession.clock(65), "01:05")
        XCTAssertEqual(FocusSession.clock(3725), "1:02:05")
    }
}

/// 专注计时窗口的样式与隐藏。
@MainActor
final class FocusPanelStyleTests: XCTestCase {
    override func setUp() async throws {
        // 先建好应用对象：直接从 NSPanel 的初始化里首次创建它会重入而崩溃。
        _ = NSApplication.shared
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "focus-panel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist"))
        }
        return defaults
    }

    private func makeSession() throws -> (FocusSession, ScheduledTask) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let task = try XCTUnwrap(store.addParsedTodo("读论文 [链接](https://example.com/a)", on: Date()))
        let session = FocusSession()
        session.store = store
        session.openLink = { _ in }
        session.activateExistingTab = { _ in false }
        return (session, task)
    }

    func testEveryStyleHasATitleAndOnlyMenuBarHasNoFloatingWindow() {
        XCTAssertEqual(FocusPanelStyle.allCases.count, 5)
        XCTAssertEqual(Set(FocusPanelStyle.allCases.map(\.title)).count, 5)
        XCTAssertNil(FocusPanelStyle.menuBar.panelSize)
        for style in FocusPanelStyle.allCases where style != .menuBar {
            XCTAssertEqual(style.panelSize, NSSize(width: 340, height: 158), "工作台样式统一使用固定尺寸")
        }
    }

    func testVisibilityRulesCombineActiveHiddenAndStyle() {
        for style in FocusPanelStyle.allCases {
            XCTAssertFalse(FocusPanelStyle.floatingVisible(active: false, hidden: false, style: style), "没在专注就什么都不显示")
            XCTAssertFalse(FocusPanelStyle.floatingVisible(active: true, hidden: true, style: style), "隐藏时什么都不显示")
            XCTAssertFalse(FocusPanelStyle.menuBarVisible(active: true, hidden: true, style: style))
        }
        XCTAssertTrue(FocusPanelStyle.floatingVisible(active: true, hidden: false, style: .pill))
        XCTAssertFalse(FocusPanelStyle.floatingVisible(active: true, hidden: false, style: .menuBar), "菜单栏样式没有独立面板")
        XCTAssertTrue(FocusPanelStyle.menuBarVisible(active: true, hidden: false, style: .menuBar))
        XCTAssertFalse(FocusPanelStyle.menuBarVisible(active: true, hidden: false, style: .card))
    }

    func testControllerFollowsSessionStyleAndHiddenPreferences() async throws {
        let defaults = makeDefaults()
        let (session, task) = try makeSession()
        let controller = FocusPanelController(session: session, defaults: defaults)
        XCTAssertFalse(controller.isPanelVisible)

        session.start(task: task, url: URL(string: "https://example.com/a")!)
        XCTAssertTrue(controller.isPanelVisible, "默认卡片样式：开始专注就显示浮窗")
        XCTAssertFalse(controller.showsMenuBarTimer)

        defaults.set(true, forKey: Prefs.focusPanelHidden)
        controller.refresh()
        XCTAssertFalse(controller.isPanelVisible, "隐藏：专注还在，窗口没了")
        XCTAssertNotNil(session.active, "隐藏不影响专注本身")
        defaults.set(false, forKey: Prefs.focusPanelHidden)
        controller.refresh()
        XCTAssertTrue(controller.isPanelVisible)

        defaults.set(FocusPanelStyle.menuBar.rawValue, forKey: Prefs.focusPanelStyle)
        controller.refresh()
        XCTAssertTrue(controller.isPanelVisible, "工作台在不同显示偏好下仍保持统一尺寸")
        XCTAssertFalse(controller.showsMenuBarTimer, "统一工作台不再额外创建菜单栏计时")

        defaults.set(true, forKey: Prefs.focusPanelHidden)
        controller.refresh()
        XCTAssertFalse(controller.showsMenuBarTimer, "隐藏时菜单栏里也没有")
        let end = try XCTUnwrap(session.active).started.addingTimeInterval(try XCTUnwrap(session.active).plannedSeconds + 1)
        session.tick(now: end)
        XCTAssertTrue(session.needsReflection)
        XCTAssertTrue(controller.isPanelVisible, "到点后重新显示隐藏的面板以填写反馈")
        XCTAssertFalse(defaults.bool(forKey: Prefs.focusPanelHidden))
        defaults.set(false, forKey: Prefs.focusPanelHidden)
        defaults.set(FocusPanelStyle.dot.rawValue, forKey: Prefs.focusPanelStyle)
        controller.refresh()
        XCTAssertTrue(controller.isPanelVisible)
        XCTAssertFalse(controller.showsMenuBarTimer)

        session.stop(reason: "手动结束")
        XCTAssertFalse(controller.isPanelVisible, "结束专注后窗口消失")
        XCTAssertFalse(controller.showsMenuBarTimer)
    }

    func testToggleHiddenFlipsTheStoredPreferenceAndUnknownStyleFallsBackToCard() {
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: Prefs.focusPanelHidden)
        addTeardownBlock { if let before { defaults.set(before, forKey: Prefs.focusPanelHidden) } else { defaults.removeObject(forKey: Prefs.focusPanelHidden) } }
        defaults.set(false, forKey: Prefs.focusPanelHidden)
        FocusPanelStyle.toggleHidden()
        XCTAssertTrue(FocusPanelStyle.hidden)
        FocusPanelStyle.toggleHidden()
        XCTAssertFalse(FocusPanelStyle.hidden)
        XCTAssertNil(FocusPanelStyle(rawValue: "nonsense"))
    }

    func testEveryStyleRendersAtItsPanelSize() throws {
        let (session, task) = try makeSession()
        session.start(task: task, url: URL(string: "https://example.com/a")!)
        addTeardownBlock { session.stop(reason: "测试结束") }
        for style in FocusPanelStyle.allCases {
            guard let size = style.panelSize else { continue }
            UserDefaults.standard.set(style.rawValue, forKey: Prefs.focusPanelStyle)
            let host = NSHostingView(rootView: FocusPanelView(session: session))
            host.setFrameSize(size)
            let window = QuietWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1, "\(style.title) 的内容放得进窗口")
            XCTAssertLessThanOrEqual(host.fittingSize.height, size.height + 1)
            XCTAssertGreaterThan(host.fittingSize.height, 6)
        }
        let current = try XCTUnwrap(session.active)
        session.tick(now: current.started.addingTimeInterval(current.plannedSeconds + 1))
        let reflection = NSHostingView(rootView: FocusPanelView(session: session))
        reflection.setFrameSize(NSSize(width: 340, height: 158))
        reflection.layoutSubtreeIfNeeded()
        XCTAssertEqual(reflection.fittingSize.width, 340, accuracy: 1)
        XCTAssertEqual(reflection.fittingSize.height, 158, accuracy: 1)
        UserDefaults.standard.removeObject(forKey: Prefs.focusPanelStyle)
    }
}
