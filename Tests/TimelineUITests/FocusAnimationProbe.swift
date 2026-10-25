import AppKit
import SwiftUI
import XCTest
@testable import Timeline

/// 小伙伴呼吸动画的主线程开销：SwiftUI repeatForever（旧做法）对比 Core Animation。`TIMELINE_MEMORY_PROBE=1` 时才运行。
@MainActor
final class FocusAnimationProbe: XCTestCase {
    private struct OldHalo: View {
        @State private var breathing = false
        var body: some View {
            Circle().fill(Palette.accent.opacity(breathing ? 0.22 : 0.08)).frame(width: 30, height: 30)
                .scaleEffect(breathing ? 1.08 : 0.92)
                .onAppear { withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathing = true } }
        }
    }

    private func cpu() -> Double { var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }

    private func measure<V: View>(_ label: String, _ view: V, check: () -> Void = {}) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: view.frame(width: 340, height: 60))
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let before = cpu()
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        print(String(format: "PROBE %@: %.1f ms main-thread CPU per second", label, (cpu() - before) / 3 * 1000))
        check()
        window.orderOut(nil)
        window.contentView = nil
    }

    func testBreathingCost() throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_MEMORY_PROBE"] != nil else { throw XCTSkip("probe only") }
        _ = NSApplication.shared
        measure("idle", Color.clear)
        measure("SwiftUI repeatForever", OldHalo())
        FocusBreathingHaloView.animatesInTests = true
        defer { FocusBreathingHaloView.animatesInTests = false }
        let view = FocusBreathingHaloView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        measure("Core Animation", FocusHaloProbeWrapper(view: view)) {
            print("PROBE CA animation attached: \(view.halo.animation(forKey: FocusBreathingHaloView.animationKey) != nil)")
        }
    }
}

private struct FocusHaloProbeWrapper: NSViewRepresentable {
    let view: FocusBreathingHaloView
    func makeNSView(context: Context) -> FocusBreathingHaloView { view }
    func updateNSView(_ nsView: FocusBreathingHaloView, context: Context) {}
}
