import AppKit
import SwiftUI

/// 两个页面保留原生控件和滚动位置；切换只改变可见性，不触发重新挂载。
/// 每页第一次显示时才创建：只用其中一页时，另一页不占内存，也不跟着每次修改重算。
struct RetainedWorkspacePages<First: View, Second: View>: NSViewRepresentable {
    let showsFirst: Bool
    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second

    final class Coordinator {
        var first: NSHostingView<AnyView>?
        var second: NSHostingView<AnyView>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        if showsFirst, coordinator.first == nil { coordinator.first = Self.page(in: view) }
        if !showsFirst, coordinator.second == nil { coordinator.second = Self.page(in: view) }
        coordinator.first?.rootView = AnyView(first().environment(\.self, context.environment))
        coordinator.second?.rootView = AnyView(second().environment(\.self, context.environment))
        coordinator.first?.isHidden = !showsFirst
        coordinator.second?.isHidden = showsFirst
    }

    private static func page(in view: NSView) -> NSHostingView<AnyView> {
        let page = NSHostingView(rootView: AnyView(EmptyView()))
        page.frame = view.bounds
        page.autoresizingMask = [.width, .height]
        view.addSubview(page)
        return page
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        view.subviews.forEach { $0.removeFromSuperview() }
    }
}
