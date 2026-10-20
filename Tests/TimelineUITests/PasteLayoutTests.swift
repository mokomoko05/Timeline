import AppKit
import SwiftUI
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class PasteLayoutTests: XCTestCase {

    private func editor(in view: NSView) -> ImagePasteTextView? {
        if let editor = view as? ImagePasteTextView { return editor }
        return view.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }

    func testQuickCapturePasteSample() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let model = QuickCaptureModel()
        model.mode = .log
        let host = NSHostingView(rootView: QuickCaptureView(store: store, model: model, close: {}, resize: { _ in }))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let input = try XCTUnwrap(editor(in: host))
        window.makeFirstResponder(input)
        let started = CFAbsoluteTimeGetCurrent()
        let board = NSPasteboard(name: .init("paste-layout-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString(Self.sample, forType: .string)
        XCTAssertTrue(input.readSelection(from: board, type: .string))
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(model.text, Self.sample)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 3)
        XCTAssertEqual(input.string, Self.sample)
        input.delegate = nil
        XCTAssertGreaterThan(input.frame.height, input.enclosingScrollView!.contentSize.height)
        window.contentView = nil
        window.close()
    }

    func testNotesPasteSample() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let task = try XCTUnwrap(store.addParsedTodo("Reading", on: Date()))
        let nav = NotesNavigation()
        nav.open(task: task.id)
        let host = NSHostingView(rootView: NotesView(store: store, initialSelection: task.id, nav: nav, reveal: { _ in }, openDay: { _ in }))
        let window = QuietWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let input = try XCTUnwrap(editor(in: host))
        window.makeFirstResponder(input)
        let started = CFAbsoluteTimeGetCurrent()
        let board = NSPasteboard(name: .init("paste-layout-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString(Self.sample, forType: .string)
        XCTAssertTrue(input.readSelection(from: board, type: .string))
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(nav.draft(NotesNavigation.draftKey(task: task.id)).text, Self.sample)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 3)
        XCTAssertEqual(input.string, Self.sample)
        input.delegate = nil
        XCTAssertGreaterThan(input.frame.height, input.enclosingScrollView!.contentSize.height)
        window.contentView = nil
        window.close()
    }
    func testCachedMeasurementTracksTextFontLineLimitAndPadding() {
        let measurer = InputHeightMeasurer()
        let font = NSFont.systemFont(ofSize: 13)
        func height(_ text: String, font: NSFont, width: CGFloat = 300, minimum: CGFloat = 24, lines: Int = 10) -> CGFloat {
            measurer.height(for: text, font: font, width: width, minHeight: minimum, maxLines: lines)
        }
        XCTAssertEqual(height("", font: font), 24)
        let full = height(Self.sample, font: font)
        XCTAssertGreaterThan(full, 24)
        XCTAssertLessThan(height(Self.sample, font: font, lines: 2), full)
        XCTAssertEqual(height(Self.sample, font: font, minimum: 34), full + 10)
        XCTAssertGreaterThan(height(Self.sample, font: .systemFont(ofSize: 20)), full)
        XCTAssertEqual(height("short", font: font), 24)
        XCTAssertGreaterThan(height("short\n", font: font), 24)
        XCTAssertTrue(height(Self.sample, font: font, width: .infinity).isFinite)
        XCTAssertTrue(height(Self.sample, font: font, width: 0).isFinite)
        let paragraph = String(repeating: "中文 English text ", count: 10)
        XCTAssertGreaterThan(height(paragraph, font: font, width: 100), height(paragraph, font: font, width: 600))
    }

    // User-provided regression sample: multi-paragraph text with Chinese, English and Markdown tables.
    private static let sample = #"""
# TreeSpark（旧版，免训练）阅读摘要

- 论文：TreeSpark: Calibrated, Load-Adaptive Draft Trees for Semi-Autoregressive Speculative Decoding
- 链接：https://arxiv.org/abs/2609.22098　代码：github.com/PopSoda2002/TreeSpark
- 一句话：不重训 DSpark drafter，直接用它自带的 Markov 头为"每个具体父节点"打条件分，再把条件分校准成"边被接受的概率"，用路径存活概率同时决定展开顺序、每轮树大小和服务负载下的树大小；采样时保持无损。

## 1. 要解决的问题

| 问题 | 论文的判断 |
|---|---|
| 块 drafter 的边际分布不区分父节点 | 在边际分上建树，同一深度给不同父节点相同的子节点分布，加宽只会加入排序差的节点 |
| 固定节点预算 | 每轮、每种负载能承受的投机量不同；大树在 batch 小时有利，并发上去后会变成负收益 |
| 采样（T>0）下建树 | 用确定性 top-k 子节点再做递归拒绝采样会有偏，输出不再服从目标分布 |

## 2. 方法与主要设计

| 组件 | 设计 | 关键细节 |
|---|---|---|
| 父节点条件化展开 | 一次骨干前向得到各位置基础 logits U_d；对具体父节点 x_p，用 Markov 头加低秩转移偏置：q0,d(·\|x_p)=softmax(U_d + B(x_p,·)) | 评估一个新父节点只需一次嵌入查表和一次 \|V\|×r 矩阵向量乘，不需要再跑骨干；每个节点约 80M FLOPs，对比省下的每个目标 token 前向约 8 GFLOPs |
| 边接受概率校准 | p̂ = σ(a·logit(q0)+b)，部署值 a=0.67，b=-0.46 | 标签来自树验证本身（每个被实例化的节点都知道是否匹配目标在其父节点处的预测），无需额外目标前向；**只在"祖先都被接受"的边上拟合**，因为路径存活概率估计的正是这一群体 |
| 丢弃训练好的置信头 | 只用校准后的 q0 | 置信头看不到候选 token，同一父节点下的兄弟得到同分，AUC 只有 0.699，对 logit(q) 的增益几乎为零 |
| 最优先展开 + 价格停止 | 以路径存活概率（各边 p̂ 之积）为堆优先级；最优剩余候选存活概率低于 θ 就停；节点上限 64，兄弟上限 K | θ 的含义：每多验证一个 token，期望至少多接受多少 token；固定预算是 θ=0 的特例 |
| 无损采样树 | 无放回采样兄弟：第 j 个兄弟从去掉已抽兄弟后重归一化的 q_T 中抽；验证时按抽取顺序逐字节复现各提案，再做递归拒绝采样 | Proposition 1 证明只要"每个新槽位在其值被观察前就已被接纳"即无损；有放回抽样会塌缩（τ 2.10 对 4.94） |
| 负载感知 | 实测步时延 L(bs,N)；每个请求按边际价格分配节点，退化为统一的 θ 规则；离线用 A/B 实测构造 θ*(bs,T) 价格阶梯 | 负载升高时树收缩到链，再到不投机；bs=16 且 T>0 时没有任何分叉树快于链，阶梯直接选链 |

## 3. 实验设置

| 项 | 内容 |
|---|---|
| 目标/drafter | Qwen3-4B/8B/14B；官方 DeepSpec 检查点 dspark_qwen3_*_block7（块长 b=7，Markov 秩 r=256），以及同架构去掉 Markov 头和置信头的 dflash 版本 |
| 评测集 | GSM8K、MATH-500、HumanEval、MBPP、MT-Bench、Alpaca 各 25 条，生成 200 新 token；补充 AIME25、LiveCodeBench、Arena-Hard-v2 |
| 硬件/指标 | 主要 H200（bf16、SDPA）和 A100；τ=每次目标前向生成 token 数（接受长度+1）、对匹配的纯目标解码的加速比 AR、已验证节点利用率 |

## 4. 主要结果

| 结论 | 数字 |
|---|---|
| 边际树在 DSpark 上失败 | 把 DDTree 的建树方式搬到 DSpark，N=7 时 τ 只有 2.60–2.72，N=28 也只有 3.14–3.33，都低于 N=7 的链（4.39–4.61）；在 DFlash 上同一建树方式正常，对链 +6–8% |
| 父节点条件化有效 | 同预算对 DDTree：τ +9–16%；N=56 时对链 +31–33%；4B 上 TreeSpark N=14 的 τ（5.18）≥ DDTree N=56（5.13） |
| 自适应预算优于固定预算 | 对固定 N=28：τ +0.073 且每轮少验证 5.2 个 token；θ=0.02 比固定 N=56 的 τ 只低 0.12，验证成本少 59%；每轮树大小 p10 约 7，p90 约 38 |
| 校准是必要的 | 校准用"全部边"拟合会让停止规则变差；用"祖先被接受的边"拟合后 τ 再 +0.14 到 +0.43；θ=0.15 时 τ 为 5.35 对 4.92 |
| 只重排序收益小 | 固定 N 下把堆优先级从 log q 换成 log p̂，τ 仅 +0.03–0.04 |
| 校准质量 | 原始 q0 系统性高估（平均预测 0.622，实际 0.498）；留出集 ECE：原始 0.042，全部边 Platt 0.059，祖先被接受边 Platt 0.0105；跨领域基本通用，换模型对需要各自重拟合 |
| H200 端到端（T=0） | θ=0.05 在 4B/8B/14B 上 AR 3.37/3.39/3.46×，对比链 3.12–3.17×；固定 N=56 因验证成本只有 2.8–3.0× |
| A100 端到端（4B） | AR：T=0 3.75× 对 3.30×；T=0.5 3.38× 对 3.14×；T=1 3.38× 对 3.06×，即 +14%/+8%/+10% |
| 负载 | A100-40GB、4B：bs≤4 时 k=1 与 k=56 的步时延都约 34–38 ms；bs=64 时 k=56 是 k=1 的 7.3 倍；真实动态批引擎（48 请求）：链比不投机 +16%，固定 N=56 为负收益，自适应比链 +2.1%；bs=1 自适应比链 +11%（CUDA graph 下 +7%） |
| 无损验证 | T=1 高熵位置的总变差：直接采样 0.066，TreeSpark 0.047，确定性 top-k 加朴素拒绝 0.462 |
| 摘要头条 | 对调好的链：每轮多接受 15%–25% 的 token，单请求快 8%–14%，负载升高时树自动收缩 |

## 5. 作者承认的局限

- 单请求墙钟在 Python 研究 harness 中测，不是连续批处理的生产实现；批量吞吐和尾延迟未测。
- 发布的 drafter 块长只有 7；Markov 头只条件化于直接父节点，深处分支趋近边际行为。
- 校准标签来自贪心匹配，T>0 的验证用拒绝规则，二者的不匹配没有被单独隔离。
- 没做 Gemma4-12B，也没和 EAGLE-3 做同环境对比。
- 同期工作：PCTree、DominoTree、JetSpec，作者认为自己的贡献在预算控制、校准和采样无损。

## 6. 阅读时的重点和与你工作的关联

- 重点看：3.4 节和 Table 6（校准的拟合群体）、3.3 节和 Table 9（无损采样）、Table 2（τ 对 N）、Table 1/3/8（价格阶梯与服务）。
- 校准群体：只在"祖先被接受"的边上拟合；全部边的拟合含"反事实上下文"，会让高置信边被系统性低估。你的校准图中高概率区间偏高，值得按"父节点是否在接受路径上"拆开再看。
- 条件分的必要性：论文里边际树只在共训的 DSpark 上失败，在只有边际监督的 DFlash 上正常；你的 DFlash 2 选择器正是在提供条件分。
- 预算：他们的 N≤64、块长 7、4B 模型；你的 B=16/24、27B 混合模型，量级和成本结构都不同，数字不要直接对比。
- 口径提醒：作者明确说不同 harness 的 τ 和 AR 不可跨表比较。
"""#
}
