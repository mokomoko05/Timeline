import AppKit
import SwiftUI

/// 两个页面保留原生控件和滚动位置；切换只改变可见性，不触发重新挂载。
struct RetainedWorkspacePages<First: View, Second: View>: NSViewRepresentable {
    let showsFirst: Bool
    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second

    final class Coordinator {
        let first = NSHostingView(rootView: AnyView(EmptyView()))
        let second = NSHostingView(rootView: AnyView(EmptyView()))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.first.rootView = AnyView(first().environment(\.self, context.environment))
        context.coordinator.second.rootView = AnyView(second().environment(\.self, context.environment))
        for page in [context.coordinator.first, context.coordinator.second] where page.superview !== view {
            page.frame = view.bounds
            page.autoresizingMask = [.width, .height]
            view.addSubview(page)
        }
        context.coordinator.first.isHidden = !showsFirst
        context.coordinator.second.isHidden = showsFirst
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        view.subviews.forEach { $0.removeFromSuperview() }
    }
}
