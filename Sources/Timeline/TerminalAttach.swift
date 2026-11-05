import AppKit
import Darwin
import Foundation
import SwiftTerm
import TimelineControl

// MARK: - 屏幕序列化

/// 把 SwiftTerm 的屏幕转成外部终端能直接显示的 ANSI 序列（颜色、样式、宽字符、光标、滚动区域）。
@MainActor
enum ScreenRenderer {
    /// 当前缓冲区的总行数（回滚 + 屏幕）。SwiftTerm 没公开，用二分查找按公开接口求出来。
    static func lineCount(_ terminal: Terminal) -> Int {
        let base = terminal.buffer.totalLinesTrimmed
        func valid(_ index: Int) -> Bool { terminal.getScrollInvariantLine(row: base + index) != nil }
        guard valid(0) else { return 0 }
        var low = 0, high = max(terminal.rows, 1)
        while valid(high) { low = high; high *= 2 }
        while high - low > 1 {
            let middle = (low + high) / 2
            if valid(middle) { low = middle } else { high = middle }
        }
        return high
    }

    /// 第 `index` 行（从缓冲区顶部数，含回滚）。
    static func line(_ terminal: Terminal, _ index: Int) -> BufferLine? {
        terminal.getScrollInvariantLine(row: terminal.buffer.totalLinesTrimmed + index)
    }

    /// 屏幕第一行在缓冲区里的位置（不受 Timeline 窗口里向上滚动的影响）。
    static func screenTop(_ terminal: Terminal) -> Int {
        max(0, lineCount(terminal) - terminal.rows)
    }

    private static func color(_ color: Attribute.Color, foreground: Bool) -> String? {
        switch color {
        case .ansi256(let code):
            if code < 8 { return "\(Int(code) + (foreground ? 30 : 40))" }
            if code < 16 { return "\(Int(code) - 8 + (foreground ? 90 : 100))" }
            return "\(foreground ? 38 : 48);5;\(code)"
        case .trueColor(let red, let green, let blue):
            return "\(foreground ? 38 : 48);2;\(red);\(green);\(blue)"
        case .defaultColor, .defaultInvertedColor:
            return nil
        }
    }

    static func sgr(_ attribute: Attribute) -> String {
        var parts = ["0"]
        let style = attribute.style
        if style.contains(.bold) { parts.append("1") }
        if style.contains(.dim) { parts.append("2") }
        if style.contains(.italic) { parts.append("3") }
        switch attribute.underlineStyle {
        case .none: if style.contains(.underline) { parts.append("4") }
        case .single: parts.append("4")
        case .double: parts.append("4:2")
        case .curly: parts.append("4:3")
        case .dotted: parts.append("4:4")
        case .dashed: parts.append("4:5")
        }
        if style.contains(.blink) { parts.append("5") }
        if style.contains(.inverse) { parts.append("7") }
        if style.contains(.invisible) { parts.append("8") }
        if style.contains(.crossedOut) { parts.append("9") }
        if let fg = color(attribute.fg, foreground: true) { parts.append(fg) }
        if let bg = color(attribute.bg, foreground: false) { parts.append(bg) }
        if let underline = attribute.underlineColor, let value = color(underline, foreground: true) {
            parts.append("58" + value.dropFirst(2))
        }
        return "\u{1b}[" + parts.joined(separator: ";") + "m"
    }

    private static func isBlank(_ character: Character, _ attribute: Attribute) -> Bool {
        guard character == " " || character == "\u{0}" else { return false }
        let style = attribute.style
        let background: Bool
        switch attribute.bg { case .defaultColor, .defaultInvertedColor: background = true; default: background = false }
        return background && !style.contains(.inverse) && !style.contains(.underline) && attribute.underlineStyle == .none
    }

    /// 一行的内容，最多 `cols` 列；末尾的空白不输出。结尾总是复位样式。
    static func row(_ terminal: Terminal, _ line: BufferLine?, cols: Int) -> String {
        guard let line, cols > 0 else { return "" }
        let count = min(cols, line.count)
        var cells: [(Character, Attribute, Int)] = []
        cells.reserveCapacity(count)
        var column = 0
        var index = 0
        while index < line.count, column < cols {
            let cell = line[index]
            index += 1
            let width = Int(cell.width)
            if width == 0 { continue }   // 宽字符的后半格
            var character = terminal.getCharacter(for: cell)
            if character == "\u{0}" { character = " " }
            if width == 2, column + 1 >= cols {
                // 宽字符放不下：用空格占住最后一列。
                cells.append((" ", cell.attribute, 1))
                column += 1
                continue
            }
            cells.append((character, cell.attribute, width))
            column += width
        }
        _ = count
        while let last = cells.last, isBlank(last.0, last.1) { cells.removeLast() }
        var text = ""
        var current: Attribute?
        for (character, attribute, _) in cells {
            if attribute != current {
                text += sgr(attribute)
                current = attribute
            }
            text.append(character)
        }
        if current != nil { text += "\u{1b}[0m" }
        return text
    }

    private static func cursorAndRegion(_ terminal: Terminal, modes: TerminalModes) -> String {
        let buffer = terminal.buffer
        var text = ""
        if buffer.scrollTop != 0 || buffer.scrollBottom != terminal.rows - 1 {
            text += "\u{1b}[\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r"
        }
        text += "\u{1b}[\(min(buffer.y, terminal.rows - 1) + 1);\(min(buffer.x, terminal.cols - 1) + 1)H"
        text += modes.isOn(25) ? "\u{1b}[?25h" : "\u{1b}[?25l"
        return text
    }

    /// 尺寸一致的外部终端从这份快照开始，之后直接接收原始输出。
    /// 备用屏幕开着时先画普通屏幕（纯文字）再切进备用屏幕，程序退出备用屏幕时外部终端下面也是对的。
    static func snapshot(_ terminal: Terminal, modes: TerminalModes, history: Int) -> [UInt8] {
        let rows = terminal.rows, cols = terminal.cols
        var text = "\u{1b}[0m\u{1b}[r\u{1b}[?1049l\u{1b}[H\u{1b}[2J"
        if terminal.isCurrentBufferAlternate {
            var normal = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self).components(separatedBy: "\n")
            if normal.last == "" { normal.removeLast() }
            for (index, line) in normal.suffix(rows).enumerated() {
                text += "\u{1b}[\(index + 1);1H" + String(line.prefix(cols))
            }
            text += "\u{1b}[?1049h\u{1b}[H\u{1b}[2J"
            let top = screenTop(terminal)
            for row in 0..<rows {
                text += "\u{1b}[\(row + 1);1H" + self.row(terminal, line(terminal, top + row), cols: cols)
            }
        } else {
            let top = screenTop(terminal)
            let start = max(0, top - max(0, history))
            // 回滚行顺序输出，滚进外部终端自己的回滚区；屏幕正好占满最后 rows 行。
            for index in start..<top {
                text += self.row(terminal, line(terminal, index), cols: cols) + "\r\n"
            }
            for row in 0..<rows {
                text += self.row(terminal, line(terminal, top + row), cols: cols)
                if row < rows - 1 { text += "\r\n" }
            }
        }
        return Array(modes.restoreSequence) + Array(text.utf8) + Array(cursorAndRegion(terminal, modes: modes).utf8)
    }

    /// 尺寸不一致的外部终端：按它自己的大小画一帧（多出来的地方画边框，不够的地方裁掉并在右下角标出）。
    /// 返回每一行的完整内容，调用方只发送变化的行。
    static func frame(_ terminal: Terminal, cols: Int, rows: Int, paneID: String) -> [String] {
        let paneCols = terminal.cols, paneRows = terminal.rows
        let top = screenTop(terminal)
        let visibleCols = min(cols, paneCols), visibleRows = min(rows, paneRows)
        let cropped = cols < paneCols || rows < paneRows
        var lines: [String] = []
        for row in 0..<rows {
            var text: String
            if row < visibleRows {
                text = self.row(terminal, line(terminal, top + row), cols: visibleCols)
                if cols > paneCols {
                    text += "\u{1b}[\(row + 1);\(paneCols + 1)H\u{1b}[2m│\u{1b}[0m"
                }
            } else if row == paneRows {
                text = "\u{1b}[2m" + String(repeating: "─", count: visibleCols) + (cols > paneCols ? "┘" : "") + "\u{1b}[0m"
            } else {
                text = ""
            }
            lines.append(text)
        }
        if cropped, rows > 0 {
            let badge = " \(paneID) \(paneCols)x\(paneRows) cropped "
            if cols > badge.count {
                let column = cols - badge.count
                lines[rows - 1] = (rows - 1 < visibleRows ? self.row(terminal, line(terminal, top + rows - 1), cols: column) : "")
                    + "\u{1b}[\(rows);\(column + 1)H\u{1b}[0;7m" + badge + "\u{1b}[0m"
            }
        }
        return lines
    }

    static func frameCursor(_ terminal: Terminal, cols: Int, rows: Int, modes: TerminalModes) -> String {
        let buffer = terminal.buffer
        guard modes.isOn(25), buffer.x < cols, buffer.y < rows else { return "\u{1b}[?25l" }
        return "\u{1b}[\(buffer.y + 1);\(buffer.x + 1)H\u{1b}[?25h"
    }
}

// MARK: - 连接

/// 一个 attach 上来的外部终端。IO 在自己的线程上，状态（尺寸、模式等）只在主线程上改。
final class AttachSession: @unchecked Sendable {
    let id: Int
    let readOnly: Bool
    // 以下只在主线程上读写。
    var cols: Int
    var rows: Int
    var activity = 0
    var passthrough = false
    var syncedSize: (cols: Int, rows: Int)?
    var pendingHistory: Int
    var lastFrame: [String]?
    var lastCursor = ""
    var lastModes: TerminalModes?
    var resyncing = false

    private let lock = NSLock()
    private var outbox: [UInt8] = []
    private var fd: Int32 = -1
    private var writing = false
    private var closed = false
    private var closeWhenDrained = false
    private var overflowed = false
    private let writeQueue: DispatchQueue
    static let outboxLimit = 4 << 20

    init(id: Int, readOnly: Bool, cols: Int, rows: Int, history: Int) {
        self.id = id
        self.readOnly = readOnly
        self.cols = cols
        self.rows = rows
        pendingHistory = history
        writeQueue = DispatchQueue(label: "Timeline.Attach.\(id).write", qos: .userInitiated)
    }

    /// 排进发送队列。积压超过上限时整个丢掉，返回 false（调用方随后重发一份快照）。
    @discardableResult
    func enqueue(_ frame: AttachFrame) -> Bool {
        let bytes = frame.encoded
        lock.lock()
        if closed || closeWhenDrained { lock.unlock(); return true }
        outbox.append(contentsOf: bytes)
        if outbox.count > Self.outboxLimit {
            outbox.removeAll()
            overflowed = true
            lock.unlock()
            return false
        }
        let start = fd >= 0 && !writing
        if start { writing = true }
        lock.unlock()
        if start { writeQueue.async { [self] in drain() } }
        return true
    }

    func output(_ bytes: [UInt8]) -> Bool {
        bytes.isEmpty ? true : enqueue(AttachFrame(.output, bytes))
    }

    /// 握手应答写完之后由服务端调用：开始收发。
    func start(fd: Int32, leftover: [UInt8], onFrame: @escaping @Sendable (AttachFrame) -> Void, onClose: @escaping @Sendable () -> Void) {
        lock.lock()
        if closed {
            lock.unlock()
            Darwin.close(fd)
            onClose()
            return
        }
        self.fd = fd
        let start = !outbox.isEmpty && !writing
        if start { writing = true }
        lock.unlock()
        if start { writeQueue.async { [self] in drain() } }
        let thread = Thread { [self] in readLoop(fd: fd, leftover: leftover, onFrame: onFrame, onClose: onClose) }
        thread.name = "Timeline.Attach.\(id).read"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func readLoop(fd: Int32, leftover: [UInt8], onFrame: @escaping @Sendable (AttachFrame) -> Void, onClose: @escaping @Sendable () -> Void) {
        var decoder = AttachFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending = leftover
        reading: while true {
            if !pending.isEmpty {
                guard let frames = try? decoder.append(pending) else { break }
                pending = []
                for frame in frames {
                    onFrame(frame)
                    if frame.type == .detach { break reading }
                }
            }
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            pending = Array(buffer[0..<count])
        }
        lock.lock()
        closed = true
        self.fd = -1
        lock.unlock()
        // 写线程可能还在用这个 fd：等它退出再关。
        writeQueue.async { Darwin.close(fd) }
        onClose()
    }

    private func drain() {
        while true {
            lock.lock()
            let fd = self.fd
            if outbox.isEmpty || fd < 0 {
                writing = false
                let shut = closeWhenDrained && fd >= 0
                lock.unlock()
                if shut { shutdown(fd, SHUT_RDWR) }
                return
            }
            let chunk = outbox
            outbox.removeAll(keepingCapacity: true)
            lock.unlock()
            if (try? ControlSocket.writeAll(fd, Data(chunk))) == nil {
                lock.lock()
                outbox.removeAll()
                writing = false
                lock.unlock()
                shutdown(fd, SHUT_RDWR)
                return
            }
        }
    }

    /// 发完已排队的内容（比如 exit 帧）后断开。
    func finish() {
        lock.lock()
        closeWhenDrained = true
        let fd = self.fd
        let idle = !writing
        if idle { writing = true }
        lock.unlock()
        if idle, fd >= 0 { writeQueue.async { [self] in drain() } } else if idle {
            lock.lock(); writing = false; closed = true; lock.unlock()
        }
    }

    /// 立即断开（不再发送）。
    func close() {
        lock.lock()
        closed = true
        outbox.removeAll()
        let fd = self.fd
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }
}

// MARK: - 窗格上的 attach

/// 一个窗格的所有外部连接。尺寸按 tmux 的 latest：最近输入的一方（包括 Timeline 窗口本身）决定 PTY 尺寸；
/// 尺寸一致的外部终端直接接收原始输出，不一致的按自己的大小看到裁剪或加边框的画面。
@MainActor
final class AttachHub {
    unowned let pane: PaneTerminalView
    let filter = TerminalStreamFilter()
    private(set) var sessions: [AttachSession] = []
    /// 当前决定尺寸的外部终端；nil 表示 Timeline 窗口。
    private(set) var owner: AttachSession?
    private var tick = 0
    private var localActivity = 0
    private var renderScheduled = false
    private var nextID = 1
    private var ended = false

    init(pane: PaneTerminalView) { self.pane = pane }

    var count: Int { sessions.count }

    // MARK: 输出

    /// 测试测速用：每批输出到达时调用。
    var onReceived: (() -> Void)?

    /// PTY 输出，先于 SwiftTerm 渲染调用。
    func received(_ bytes: ArraySlice<UInt8>) {
        onReceived?()
        let forward = sessions.contains { $0.passthrough && !$0.resyncing }
        let filtered = filter.process(bytes, forward: forward)
        guard !sessions.isEmpty else { return }
        for session in sessions where session.passthrough && !session.resyncing {
            if !session.output(filtered) { resync(session) }
        }
        if sessions.contains(where: { !$0.passthrough }) { scheduleRender() }
    }

    /// 积压太多：丢掉之后的输出，等这一批渲染完，再发一份完整快照。
    private func resync(_ session: AttachSession) {
        session.resyncing = true
        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
            session.resyncing = false
            session.syncedSize = nil
            self.reconcile(session)
        }
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            self?.renderFrames()
        }
    }

    private func renderFrames() {
        renderScheduled = false
        let terminal = pane.getTerminal()
        for session in sessions where !session.passthrough {
            var text = ""
            if session.lastModes != filter.modes {
                session.lastModes = filter.modes
                text += String(decoding: filter.modes.restoreSequence, as: UTF8.self)
            }
            let frame = ScreenRenderer.frame(terminal, cols: session.cols, rows: session.rows, paneID: pane.paneID)
            let previous = session.lastFrame
            for (index, line) in frame.enumerated() where previous == nil || previous!.count != frame.count || previous![index] != line {
                text += "\u{1b}[\(index + 1);1H\u{1b}[0m\u{1b}[2K" + line
            }
            session.lastFrame = frame
            let cursor = ScreenRenderer.frameCursor(terminal, cols: session.cols, rows: session.rows, modes: filter.modes)
            if !text.isEmpty || cursor != session.lastCursor {
                text += cursor
                session.lastCursor = cursor
                if !session.output(Array(text.utf8)) { session.lastFrame = nil; scheduleRender() }
            }
        }
    }

    // MARK: 连接管理

    func attach(cols: Int, rows: Int, readOnly: Bool, history: Int) -> AttachSession {
        let session = AttachSession(id: nextID, readOnly: readOnly, cols: cols, rows: rows, history: history)
        nextID += 1
        sessions.append(session)
        if !readOnly {
            tick += 1
            session.activity = tick
            owner = session
        }
        applySize()
        return session
    }

    func handle(_ frame: AttachFrame, from session: AttachSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        switch frame.type {
        case .input:
            guard !session.readOnly, !frame.payload.isEmpty, let process = pane.process, process.running else { return }
            tick += 1
            session.activity = tick
            if owner !== session {
                owner = session
                applySize()
            }
            process.send(data: frame.payload[...])
        case .resize:
            guard let size = frame.size, size.cols > 0, size.rows > 0 else { return }
            session.cols = min(size.cols, 1000)
            session.rows = min(size.rows, 1000)
            if owner === session { applySize() } else { reconcile(session) }
        case .detach:
            remove(session)
        default:
            break
        }
    }

    func remove(_ session: AttachSession) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        sessions.remove(at: index)
        session.close()
        if owner === session {
            // 交给剩下的里面最近输入过的一方；Timeline 窗口更近就交回窗口。
            let next = sessions.filter { !$0.readOnly }.max { $0.activity < $1.activity }
            owner = next.flatMap { $0.activity > localActivity ? $0 : nil }
        }
        applySize()
    }

    /// Timeline 窗口里的键盘或鼠标输入。
    func localInput() {
        tick += 1
        localActivity = tick
        guard owner != nil else { return }
        owner = nil
        applySize()
    }

    /// 窗格结束：通知所有外部终端后断开。
    func paneEnded(exitCode: Int32?) {
        guard !ended else { return }
        ended = true
        let all = sessions
        sessions = []
        owner = nil
        for session in all {
            session.enqueue(.exit(code: exitCode))
            session.finish()
        }
        pane.attachStateChanged()
    }

    private func applySize() {
        pane.followSize(owner.map { ($0.cols, $0.rows) })
        for session in sessions { reconcile(session) }
        pane.attachStateChanged()
    }

    /// 尺寸和 PTY 一致就直通（先发一份快照），否则按自己的大小渲染。
    private func reconcile(_ session: AttachSession) {
        let terminal = pane.getTerminal()
        let size = (cols: terminal.cols, rows: terminal.rows)
        if session.cols == size.cols, session.rows == size.rows {
            let alreadySynced = session.passthrough && session.syncedSize.map { $0 == size } == true
            guard !alreadySynced else { return }
            session.passthrough = true
            session.syncedSize = size
            session.lastFrame = nil
            session.lastModes = nil
            let snapshot = ScreenRenderer.snapshot(terminal, modes: filter.modes, history: session.pendingHistory)
            session.pendingHistory = 0
            if !session.output(snapshot) { resync(session) }
        } else {
            if session.passthrough || session.lastFrame == nil {
                session.passthrough = false
                session.syncedSize = nil
                session.lastFrame = nil
                session.lastCursor = ""
                session.lastModes = nil
                // 渲染模式在外部终端的备用屏幕里画，不污染它的回滚区。
                _ = session.output(Array("\u{1b}[?1049h\u{1b}[0m\u{1b}[r\u{1b}[H\u{1b}[2J".utf8))
            }
            scheduleRender()
        }
    }
}

// MARK: - 命令

extension ShellWindowController {
    /// `tl attach`：返回握手应答，和握手之后接管连接的回调。
    func handleAttach(_ request: ControlRequest) -> ControlReply {
        let pane: PaneTerminalView
        if let id = request.pane {
            guard let found = self.pane(withID: id) else { return ControlReply(.failure("找不到窗格 \(id)", code: "not_found")) }
            pane = found
        } else {
            guard let current = keyTerminal?.terminal as? PaneTerminalView else { return ControlReply(.failure("没有终端窗格", code: "not_found")) }
            pane = current
        }
        guard let cols = request.cols, let rows = request.rows, cols > 0, rows > 0 else {
            return ControlReply(.failure("attach 需要终端尺寸", code: "usage"))
        }
        guard pane.process?.running == true else { return ControlReply(.failure("窗格 \(pane.paneID) 已结束", code: "not_found")) }
        let hub = pane.attach
        let session = hub.attach(cols: min(cols, 1000), rows: min(rows, 1000), readOnly: request.readOnly == true, history: max(0, request.history ?? 0))
        return ControlReply(ControlResponse(panes: [pane.paneID])) { [weak hub] fd, leftover in
            session.start(fd: fd, leftover: leftover, onFrame: { frame in
                DispatchQueue.main.async { MainActor.assumeIsolated { hub?.handle(frame, from: session) } }
            }, onClose: {
                DispatchQueue.main.async { MainActor.assumeIsolated { hub?.remove(session) } }
            })
        }
    }
}
