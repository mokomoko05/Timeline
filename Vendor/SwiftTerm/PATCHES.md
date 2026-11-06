# SwiftTerm（内置副本）

来源：https://github.com/migueldeicaza/SwiftTerm v1.20.0（5d14406844143538cd8f8851d2d8a67c1fe443e5），MIT 许可证见 LICENSE。
只保留 `Sources/SwiftTerm`；构建信息插件换成静态的 `SwiftTermBuildInfo.swift`。

## 补丁

1. `BufferLine.getTrimmedLength()` 不超过行长。
   终端变窄时，光标所在行不参与重排、直接截断，宽字符（中文、emoji）可能只剩左半格留在最后一列，
   这时原实现返回 `列数 + 1`。之后再变窄，`Buffer.reflowNarrower` 按这个长度用 `copyFrom`
   拷贝，越界读写 `UnsafeMutableBufferPointer`，悄悄破坏堆，过一段时间才在无关的 malloc/free 里崩溃。
   上游 v1.99.2 仍有同样的问题。复现：11 列写入 `a中中中中中`，缩到 10 列，换行，再缩到 4 列（ASan 报 heap-buffer-overflow）。
   回归测试：`Tests/TimelineUITests/TerminalReflowTests.swift`。

上游修复后可改回远程依赖。
