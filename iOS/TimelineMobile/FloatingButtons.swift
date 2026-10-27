import SwiftUI
import UIKit

/// 右下角的浮动按钮：写一笔，左边是「回到顶部」「跳到底部」（离开顶部 / 底部一段距离才出现，和 Mac 笔记页一样）。
///
/// 滚动位置由 `ScrollEdges` 转交：页面的滚动视图每帧都在报告首尾标记的位置，但只有按钮出现 / 消失时
/// 才刷新按钮这一小块，不重算整页。页面持有它时用 `@State`（不订阅），只有按钮观察它。
@MainActor
final class ScrollEdges: ObservableObject {
    enum Edge { case top, bottom }

    static let topID = "scroll-edge-top"
    static let bottomID = "scroll-edge-bottom"
    static let space = "scroll-edges"

    @Published fileprivate(set) var showsTop = false
    @Published fileprivate(set) var showsBottom = false
    /// 当前页面的滚动视图（底下的 UIScrollView）：换页（日记换天）时由新页面接手。
    fileprivate(set) weak var scrollView: UIScrollView?
    fileprivate var proxy: ScrollViewProxy?
    /// 滚动视图滚动时（每帧）：日记页用它算出现在看到哪一条。
    var scrolled: ((UIScrollView) -> Void)?
    private var observation: NSKeyValueObservation?

    fileprivate func attach(_ view: UIScrollView) {
        guard view !== scrollView else { return }
        scrollView = view
        observation = view.observe(\.contentOffset) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.scrolled?(view) }
        }
    }

    /// 跳到顶部 / 底部。正在滑动（惯性）时也立刻跳：先停住惯性，再直接设位置。
    /// 到底部要多看几帧：懒加载的行排出来以后内容的真实高度和估算的不一样，按估算跳会落到内容下面的空白里。
    func jump(_ edge: Edge) {
        guard let view = scrollView else {
            proxy?.scrollTo(edge == .top ? Self.topID : Self.bottomID, anchor: edge == .top ? .top : .bottom)
            return
        }
        stop(view)
        if edge == .top {
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: -view.adjustedContentInset.top), animated: false)
        } else {
            settleAtBottom(view, tries: 8)
        }
    }

    /// 滚到某个视图（日记里的某一条）的开头，正在滑动也立刻停下来过去。
    func reveal(_ id: String) {
        if let view = scrollView { stop(view) }
        proxy?.scrollTo(id, anchor: .top)
    }

    private func stop(_ view: UIScrollView) {
        view.setContentOffset(view.contentOffset, animated: false)
    }

    private func settleAtBottom(_ view: UIScrollView, tries: Int) {
        view.layoutIfNeeded()
        let bottom = max(-view.adjustedContentInset.top, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
        if abs(view.contentOffset.y - bottom) > 0.5 {
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: bottom), animated: false)
        }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak view] in
            guard let self, let view, !view.isTracking else { return }
            self.settleAtBottom(view, tries: tries - 1)
        }
    }

    fileprivate func update(top: CGFloat, bottom: CGFloat, height: CGFloat) {
        let top = top < -240, bottom = bottom > height + 160
        if top != showsTop || bottom != showsBottom {
            withAnimation(Motion.adapt(.snappy(duration: 0.2))) {
                showsTop = top
                showsBottom = bottom
            }
        }
    }

    func reset() {
        if showsTop || showsBottom { showsTop = false; showsBottom = false }
    }
}

private struct ScrollEdgeKey: PreferenceKey {
    struct Value: Equatable { var top: CGFloat = -.infinity; var bottom: CGFloat = .infinity }
    static var defaultValue = Value()
    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        if next.top != -.infinity { value.top = next.top }
        if next.bottom != .infinity { value.bottom = next.bottom }
    }
}

extension View {
    /// 放在滚动内容最上面 / 最下面的占位视图上（同时是滚动的目标）。顶部的那个顺便找出底下的 UIScrollView。
    func scrollEdgeMarker(_ edge: ScrollEdges.Edge) -> some View {
        id(edge == .top ? ScrollEdges.topID : ScrollEdges.bottomID)
            .background(GeometryReader { proxy in
                let frame = proxy.frame(in: .named(ScrollEdges.space))
                Color.clear.preference(key: ScrollEdgeKey.self, value: edge == .top ? .init(top: frame.minY) : .init(bottom: frame.maxY))
            })
            .background { if edge == .top { ScrollViewFinder() } }
    }

    /// 加在滚动视图上：把首尾标记的位置交给 `edges`，并让按钮能滚动这个视图。
    func trackScrollEdges(_ edges: ScrollEdges, proxy: ScrollViewProxy) -> some View {
        modifier(ScrollEdgeTracker(edges: edges, proxy: proxy))
    }
}

private struct ScrollEdgeTracker: ViewModifier {
    let edges: ScrollEdges
    let proxy: ScrollViewProxy
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: ScrollEdges.space)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .onPreferenceChange(ScrollEdgeKey.self) { value in
                MainActor.assumeIsolated { edges.update(top: value.top, bottom: value.bottom, height: height) }
            }
            .environment(\.scrollEdges, edges)
            // 直接落到目标位置：长时间线的滚动动画一路排版，很卡。
            .onAppear { edges.proxy = proxy }
    }
}

private struct ScrollEdgesKey: EnvironmentKey {
    static let defaultValue: ScrollEdges? = nil
}

extension EnvironmentValues {
    var scrollEdges: ScrollEdges? {
        get { self[ScrollEdgesKey.self] }
        set { self[ScrollEdgesKey.self] = newValue }
    }
}

/// 放在滚动内容里的空视图：进了窗口就顺着父视图找到滚动视图，交给 `ScrollEdges`。
private struct ScrollViewFinder: UIViewRepresentable {
    @Environment(\.scrollEdges) private var edges

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.found = { [weak edges] in edges?.attach($0) }
        view.search()
    }

    final class Probe: UIView {
        var found: ((UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            search()
        }

        func search() {
            guard window != nil else { return }
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            if let scroll = view as? UIScrollView { MainActor.assumeIsolated { found?(scroll) } }
        }
    }
}

/// 右下角：跳转按钮 + 写一笔（`compose` 为 nil 时只有跳转按钮）。
struct FloatingButtons: View {
    @ObservedObject var edges: ScrollEdges
    var compose: (() -> Void)?

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(spacing: 8) {
                if edges.showsTop { jump("arrow.up", "回到顶部", .top) }
                if edges.showsBottom { jump("arrow.down", "跳到底部", .bottom) }
            }
            .padding(.bottom, compose == nil ? 0 : 6)
            if let compose {
                Button(action: compose) {
                    Image(systemName: "square.and.pencil")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Palette.accent, in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                }
                .accessibilityLabel(Text("记一笔"))
            }
        }
        .padding(20)
        .sensoryFeedback(.impact(weight: .light), trigger: tapped)
    }

    @State private var tapped = 0

    private func jump(_ symbol: String, _ title: LocalizedStringKey, _ edge: ScrollEdges.Edge) -> some View {
        Button {
            tapped += 1
            edges.jump(edge)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Palette.line.opacity(0.8), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .transition(Motion.transition(.opacity.combined(with: .scale(scale: 0.85))))
    }
}
