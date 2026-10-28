import AppKit
import CoreVideo
import QuartzCore
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

private struct ScrollFrameSample: Codable {
    let start: Double
    let queueDelayMS: Double
    let scrollMS: Double
    let layoutMS: Double
    let drawMS: Double
    let position: Double
    let movement: Double

    var workMS: Double { scrollMS + layoutMS + drawMS }
}

private struct ScrollFrameStatistics: Codable {
    let refreshMS: Double
    let frames: Int
    let movingFrames: Int
    let missedOpportunities: Int
    let hitchesOver50MS: Int
    let workOverBudget: Int
    let medianWorkMS: Double
    let p95WorkMS: Double
    let maxWorkMS: Double
    let p95IntervalMS: Double
    let maxIntervalMS: Double
    let p95QueueDelayMS: Double
    let scrollTotalMS: Double
    let layoutTotalMS: Double
    let drawTotalMS: Double
    let distance: Double

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }

    init(samples: [ScrollFrameSample], refreshMS: Double) {
        self.refreshMS = refreshMS
        frames = samples.count
        let moving = samples.filter { abs($0.movement) > 0.5 }
        movingFrames = moving.count
        let intervals = zip(samples, samples.dropFirst()).map { ($1.start - $0.start) * 1000 }
        missedOpportunities = intervals.reduce(0) { $0 + max(0, Int(($1 / refreshMS).rounded()) - 1) }
        hitchesOver50MS = intervals.filter { $0 > 50 }.count
        workOverBudget = moving.filter { $0.workMS > refreshMS }.count
        medianWorkMS = Self.percentile(moving.map(\.workMS), 0.5)
        p95WorkMS = Self.percentile(moving.map(\.workMS), 0.95)
        maxWorkMS = moving.map(\.workMS).max() ?? 0
        p95IntervalMS = Self.percentile(intervals, 0.95)
        maxIntervalMS = intervals.max() ?? 0
        p95QueueDelayMS = Self.percentile(samples.map(\.queueDelayMS), 0.95)
        scrollTotalMS = moving.reduce(0) { $0 + $1.scrollMS }
        layoutTotalMS = moving.reduce(0) { $0 + $1.layoutMS }
        drawTotalMS = moving.reduce(0) { $0 + $1.drawMS }
        distance = moving.reduce(0) { $0 + abs($1.movement) }
    }
}

private struct ScrollRefreshStatistics: Codable {
    let ticks: Int
    let coalescedTicks: Int
    let p95IntervalMS: Double
    let maxIntervalMS: Double
}

private final class ScrollRefreshClock: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var pending = false
    private var link: CVDisplayLink?
    private var action: (@MainActor (Double) -> Bool)?
    private var ticks = 0
    private var coalescedTicks = 0
    private var previousTick: Double?
    private var intervals: [Double] = []
    private(set) var refreshMS: Double = 0

    @MainActor
    func start(_ action: @escaping @MainActor (Double) -> Bool) throws {
        var created: CVDisplayLink?
        let display = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let status = display.map { CVDisplayLinkCreateWithCGDisplay($0, &created) }
            ?? CVDisplayLinkCreateWithActiveCGDisplays(&created)
        guard status == kCVReturnSuccess, let created else { throw XCTSkip("Display refresh clock unavailable: \(status)") }
        let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(created)
        guard period.timeValue > 0, period.timeScale > 0 else { throw XCTSkip("Display refresh period unavailable") }
        refreshMS = Double(period.timeValue) / Double(period.timeScale) * 1000
        self.action = action
        link = created
        lock.lock()
        active = true
        lock.unlock()
        let callbackStatus = CVDisplayLinkSetOutputCallback(created, { _, _, _, _, _, context in
            guard let context else { return kCVReturnError }
            Unmanaged<ScrollRefreshClock>.fromOpaque(context).takeUnretainedValue().tick()
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        guard callbackStatus == kCVReturnSuccess else { stop(); throw XCTSkip("Cannot set display callback: \(callbackStatus)") }
        let startStatus = CVDisplayLinkStart(created)
        guard startStatus == kCVReturnSuccess else { stop(); throw XCTSkip("Cannot start display clock: \(startStatus)") }
    }

    private func tick() {
        let issued = CACurrentMediaTime()
        lock.lock()
        guard active else { lock.unlock(); return }
        ticks += 1
        if let previousTick { intervals.append((issued - previousTick) * 1000) }
        previousTick = issued
        if pending { coalescedTicks += 1; lock.unlock(); return }
        pending = true
        lock.unlock()
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                lock.lock()
                let shouldRun = active
                lock.unlock()
                let keepRunning = shouldRun && (action?(issued) ?? false)
                lock.lock()
                pending = false
                if !keepRunning { active = false }
                lock.unlock()
            }
        }
    }

    func statistics() -> ScrollRefreshStatistics {
        lock.lock()
        defer { lock.unlock() }
        return ScrollRefreshStatistics(ticks: ticks, coalescedTicks: coalescedTicks,
                                       p95IntervalMS: ScrollFrameStatistics.percentile(intervals, 0.95),
                                       maxIntervalMS: intervals.max() ?? 0)
    }

    @MainActor
    func stop() {
        lock.lock()
        active = false
        lock.unlock()
        if let link { CVDisplayLinkStop(link) }
        link = nil
        action = nil
    }
}

@MainActor
final class ScrollFramePerformanceTests: XCTestCase {
    private struct Report: Codable {
        let label: String
        let statistics: ScrollFrameStatistics
        let displayClock: ScrollRefreshStatistics
        let samples: [ScrollFrameSample]
    }

    func testFrameStatisticsCountMissedOpportunitiesAndSeparateWorkFromQueueDelay() {
        let samples = [0.0, 0.01, 0.04, 0.10].enumerated().map { index, start in
            ScrollFrameSample(start: start, queueDelayMS: Double(index) * 2,
                              scrollMS: 1, layoutMS: index == 2 ? 12 : 2, drawMS: 1,
                              position: Double(index) * 100, movement: index == 0 ? 0 : 100)
        }
        let stats = ScrollFrameStatistics(samples: samples, refreshMS: 10)
        XCTAssertEqual(stats.frames, 4)
        XCTAssertEqual(stats.movingFrames, 3)
        XCTAssertEqual(stats.missedOpportunities, 7)
        XCTAssertEqual(stats.hitchesOver50MS, 1)
        XCTAssertEqual(stats.workOverBudget, 1)
        XCTAssertEqual(stats.medianWorkMS, 4)
        XCTAssertEqual(stats.maxWorkMS, 14)
        XCTAssertEqual(stats.maxIntervalMS, 60, accuracy: 0.001)
        XCTAssertEqual(stats.p95QueueDelayMS, 6)
        XCTAssertEqual(stats.distance, 300)
        XCTAssertEqual(stats.layoutTotalMS, 16)
        XCTAssertEqual(ScrollFrameStatistics(samples: [], refreshMS: 10).frames, 0)
    }

    func testDisplayPacedLongJournalAndNotesScrolling() async throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_FRAME_PROBE"] == "1" else { throw XCTSkip("frame probe only") }
        _ = Headless.active
        try await probeControl()
        for count in [30, 90] {
            let (store, date) = try LogScrollPerformanceProbe.makeStore(logs: count, longEvery: 3)
            defer { try? FileManager.default.removeItem(at: store.directory) }
            let workspace = NotesWorkspaceNavigation()
            workspace.open(.journal, date: date)
            try await probe("journal-\(count)", store: store, workspace: workspace, nav: NotesNavigation(defaults: InMemoryDefaults()))
        }
        let (store, date) = try LogScrollPerformanceProbe.makeStore(logs: 90, longEvery: 3)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let task = try XCTUnwrap(store.addParsedTodo("Frame probe", on: date))
        store.setLogTask(task.id, forLogs: Set(store.allLogs().map(\.id)))
        let nav = NotesNavigation(defaults: InMemoryDefaults())
        nav.open(task: task.id)
        try await probe("notes-90", store: store, workspace: NotesWorkspaceNavigation(), nav: nav)
    }

    func testDisplayPacedJournalScrollingWithDataCopy() async throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_FRAME_PROBE"] == "1",
              let source = ProcessInfo.processInfo.environment["TIMELINE_SCROLL_PROBE_DATA"] else { throw XCTSkip("data copy frame probe only") }
        _ = Headless.active
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent("journal.json"),
                                         to: directory.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: directory)
        let workspace = NotesWorkspaceNavigation()
        workspace.open(.journal, date: Date())
        try await probe("journal-data-copy", store: store, workspace: workspace, nav: NotesNavigation(defaults: InMemoryDefaults()))
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        guard !view.isHidden else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    private func probe(_ label: String, store: JournalStore, workspace: NotesWorkspaceNavigation, nav: NotesNavigation) async throws {
        let openingStarted = CACurrentMediaTime()
        let view = UnifiedNotesView(store: store, workspace: workspace, nav: nav, close: {}, reveal: { _ in }, openDay: { _ in })
            .environment(\.typography, AppTypography(scale: 1.1, lineSpacing: 0))
            .frame(width: 1424, height: 876)
        let host = NSHostingView(rootView: view)
        let window = makeWindow(content: host)
        defer { InlineMarkdownEditor.shared.finish(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        print("FRAME OPEN \(label) synchronousMS=\((CACurrentMediaTime() - openingStarted) * 1000)")
        try await Task.sleep(for: .seconds(1))
        let scroll = try XCTUnwrap(scrollViews(in: host).max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        })
        try await passes(label, scroll: scroll, host: host)
    }

    private func makeWindow(content: NSView) -> QuietWindow {
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1424, height: 876),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFront(nil)
        return window
    }

    private func probeControl() async throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1424, height: 876))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 1400, height: 30000))
        text.string = Array(repeating: "Control text 中文内容，用于检查测试驱动自身的调度开销。", count: 1500).joined(separator: "\n")
        text.isEditable = false
        text.font = .systemFont(ofSize: 14.3)
        scroll.documentView = text
        let window = makeWindow(content: scroll)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(200))
        try await passes("native-control", scroll: scroll, host: scroll)
    }

    private func passes(_ label: String, scroll: NSScrollView, host: NSView) async throws {
        scroll.verticalScrollElasticity = .none
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        for (pass, direction) in [("first-up", 1.0), ("return-down", -1.0), ("repeat-up", 1.0)] {
            let report = try await measure(label + "-" + pass, direction: direction, scroll: scroll, host: host)
            XCTAssertGreaterThan(report.statistics.movingFrames, 10, "The probe must actually scroll through content")
            XCTAssertGreaterThan(report.statistics.distance, Double(scroll.contentView.bounds.height))
            try write(report)
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func advance(_ amount: Double, scroll: NSScrollView) {
        let limit = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        let position = min(limit, max(0, scroll.contentView.bounds.minY - amount))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: position))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func measure(_ label: String, direction: Double, scroll: NSScrollView, host: NSView) async throws -> Report {
        let duration = 8.0
        let speed = 4500.0
        let done = expectation(description: label)
        let clock = ScrollRefreshClock()
        var samples: [ScrollFrameSample] = []
        var first: Double?
        var previous: Double?
        var stationary = 0
        print("FRAME BEGIN \(label) pid=\(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)
        try clock.start { issued in
            let start = CACurrentMediaTime()
            if first == nil { first = start }
            if start - first! >= duration || stationary >= 4 {
                done.fulfill()
                return false
            }
            let elapsed = previous.map { start - $0 } ?? clock.refreshMS / 1000
            previous = start
            let position = scroll.contentView.bounds.minY
            self.advance(direction * speed * elapsed, scroll: scroll)
            let afterScroll = CACurrentMediaTime()
            host.layoutSubtreeIfNeeded()
            let afterLayout = CACurrentMediaTime()
            host.displayIfNeeded()
            let afterDraw = CACurrentMediaTime()
            let actual = scroll.contentView.bounds.minY
            let movement = actual - position
            stationary = abs(movement) < 0.5 ? stationary + 1 : 0
            samples.append(ScrollFrameSample(start: start, queueDelayMS: (start - issued) * 1000,
                                             scrollMS: (afterScroll - start) * 1000, layoutMS: (afterLayout - afterScroll) * 1000,
                                             drawMS: (afterDraw - afterLayout) * 1000,
                                             position: Double(actual), movement: Double(movement)))
            return true
        }
        defer { clock.stop() }
        await fulfillment(of: [done], timeout: duration + 10)
        clock.stop()
        let stats = ScrollFrameStatistics(samples: samples, refreshMS: clock.refreshMS)
        let displayClock = clock.statistics()
        print(String(format: "FRAME %@: %.2fms refresh; %d moving/%d callbacks; missed opportunities %d; >50ms gaps %d; work median/p95/max %.2f/%.2f/%.2fms; interval p95/max %.2f/%.2fms; queue p95 %.2fms; over budget %d; scroll/layout/draw total %.1f/%.1f/%.1fms; distance %.0fpt",
                     label, stats.refreshMS, stats.movingFrames, stats.frames, stats.missedOpportunities, stats.hitchesOver50MS,
                     stats.medianWorkMS, stats.p95WorkMS, stats.maxWorkMS, stats.p95IntervalMS, stats.maxIntervalMS,
                     stats.p95QueueDelayMS, stats.workOverBudget, stats.scrollTotalMS, stats.layoutTotalMS, stats.drawTotalMS, stats.distance))
        print(String(format: "FRAME CLOCK %@: %d ticks, %d coalesced while main callback pending; source interval p95/max %.2f/%.2fms",
                     label, displayClock.ticks, displayClock.coalescedTicks, displayClock.p95IntervalMS, displayClock.maxIntervalMS))
        return Report(label: label, statistics: stats, displayClock: displayClock, samples: samples)
    }

    private func write(_ report: Report) throws {
        guard let path = ProcessInfo.processInfo.environment["TIMELINE_FRAME_PROBE_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent(report.label + ".json"), options: .atomic)
    }
}
