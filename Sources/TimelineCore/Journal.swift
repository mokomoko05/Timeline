import Foundation
import Combine

public struct Todo: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var calendarName = ""
    public var priority: TaskPriority = .normal
    /// 「不再需要做了」：已关闭但不算完成。放弃的待办 `completed` 也为 true（所以所有「未完成」的筛选、逾期、提醒都自然排除它），
    /// 用 `isDone` / `isDropped` 区分是真的做完了还是放弃了。
    public var completed: Bool
    public var dropped = false
    /// 截止日期一改，手动排的位置就作废，按新的截止时间重新排。
    public var dueDate: Date? {
        didSet { if dueDate != oldValue { listPosition = nil } }
    }
    public var dueHasTime = false
    /// 可选的计划开始时间；存在时 dueDate 是该时间段的结束时间。
    public var startDate: Date? {
        didSet { if startDate != oldValue { listPosition = nil } }
    }
    public var timeRange: DateInterval? {
        guard dueHasTime, let startDate, let dueDate, startDate < dueDate else { return nil }
        return DateInterval(start: startDate, end: dueDate)
    }
    /// 时间轴和月历按开始时间定位；纯截止任务仍按截止时间定位。
    public var timelineDate: Date? { timeRange?.start ?? dueDate }
    public var reminderMinutes: Int?
    public var repeatRule: RepeatRule = .none
    public var repeatMonthDay: Int?
    public var nextOccurrenceID: UUID?
    /// 永久编号：创建时分配，改截止日期、改顺序都不变，日志用它引用任务。
    public var number: Int?
    /// 在这个任务上累计的专注时长（秒），每次专注结束时累加。
    public var focusSeconds: TimeInterval = 0
    /// 在左侧清单里手动拖出来的位置；没有就按截止时间排。
    public var listPosition: Double?
    /// 标签（不含 `#`）：把零散的小待办归到同一个大主题下，笔记和搜索都能按标签汇总。
    public var tags: [String] = []

    /// 真的做完了（不含放弃）。
    public var isDone: Bool { completed && !dropped }
    public var isDropped: Bool { completed && dropped }

    /// 没有截止日期的任务排在最后。
    public static let undatedSortKey = 4_102_444_800.0

    /// 清单的排序键：手动位置优先，时间段按开始时间，其余按截止时间。
    public var sortKey: Double { listPosition ?? timelineDate?.timeIntervalSince1970 ?? Self.undatedSortKey }

    public var effectiveDeadline: Date? {
        guard let dueDate else { return nil }
        return dueHasTime ? dueDate : JournalDates.calendar.date(byAdding: .day, value: 1, to: JournalDates.calendar.startOfDay(for: dueDate))
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, calendarName, priority, completed, dropped, dueDate, dueHasTime, startDate, reminderMinutes, repeatRule, repeatMonthDay, nextOccurrenceID, number, focusSeconds, listPosition, tags
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        calendarName = try values.decodeIfPresent(String.self, forKey: .calendarName) ?? ""
        priority = TaskPriority(rawValue: try values.decodeIfPresent(String.self, forKey: .priority) ?? "normal") ?? .normal
        completed = try values.decode(Bool.self, forKey: .completed)
        dropped = try values.decodeIfPresent(Bool.self, forKey: .dropped) ?? false
        if !completed { dropped = false }
        dueDate = try values.decodeIfPresent(Date.self, forKey: .dueDate)
        dueHasTime = try values.decodeIfPresent(Bool.self, forKey: .dueHasTime) ?? false
        startDate = try values.decodeIfPresent(Date.self, forKey: .startDate)
        if !dueHasTime || dueDate == nil || startDate.map({ $0 >= dueDate! }) == true { startDate = nil }
        reminderMinutes = try values.decodeIfPresent(Int.self, forKey: .reminderMinutes)
        repeatRule = try values.decodeIfPresent(RepeatRule.self, forKey: .repeatRule) ?? .none
        repeatMonthDay = try values.decodeIfPresent(Int.self, forKey: .repeatMonthDay)
        nextOccurrenceID = try values.decodeIfPresent(UUID.self, forKey: .nextOccurrenceID)
        number = try values.decodeIfPresent(Int.self, forKey: .number)
        focusSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .focusSeconds) ?? 0
        listPosition = try values.decodeIfPresent(Double.self, forKey: .listPosition)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    public init(id: UUID = UUID(), title: String, completed: Bool = false) {
        self.id = id
        self.title = title
        self.completed = completed
    }
}

public struct DayEntry: Codable, Equatable {
    public var todos: [Todo] = []
    public var summary = ""
    public var logs: [DailyLogEntry] = []
    public var logDraft = ""
    public var logTaskID: UUID?
    /// 已粘贴、尚未随日志提交的图片。
    public var logDraftImages: [String] = []
    /// 草稿里用 `#` 选好的标签（日志自己的标签）。
    public var logDraftTags: [String] = []
    public var deadlines: [Todo] { todos }
    public var deadlineDraft = ""
    public var hasContent: Bool { !todos.isEmpty || !summary.isEmpty || !deadlineDraft.isEmpty || !logs.isEmpty || !logDraft.isEmpty || logTaskID != nil || !logDraftImages.isEmpty || !logDraftTags.isEmpty }
    public var completedCount: Int { todos.filter(\.isDone).count }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case todos, summary, deadline, deadlines, deadlineDraft, logs, logDraft, logTaskID, logDraftImages, logDraftTags
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        todos = try values.decode([Todo].self, forKey: .todos)
        summary = try values.decode(String.self, forKey: .summary)
        logs = try values.decodeIfPresent([DailyLogEntry].self, forKey: .logs) ?? []
        logDraft = try values.decodeIfPresent(String.self, forKey: .logDraft) ?? ""
        logTaskID = try values.decodeIfPresent(UUID.self, forKey: .logTaskID)
        logDraftImages = try values.decodeIfPresent([String].self, forKey: .logDraftImages) ?? []
        logDraftTags = try values.decodeIfPresent([String].self, forKey: .logDraftTags) ?? []
        let legacyItems: [Todo]
        if let items = try values.decodeIfPresent([Todo].self, forKey: .deadlines) {
            legacyItems = items
        } else {
            let legacyText = try values.decodeIfPresent(String.self, forKey: .deadline) ?? ""
            legacyItems = Self.deadlineItems(from: legacyText)
        }
        var identifiers = Set(todos.map(\.id))
        todos.append(contentsOf: legacyItems.filter { identifiers.insert($0.id).inserted })
        todos.removeAll { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        deadlineDraft = try values.decodeIfPresent(String.self, forKey: .deadlineDraft) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(todos, forKey: .todos)
        try values.encode(summary, forKey: .summary)
        try values.encode(logs, forKey: .logs)
        try values.encode(logDraft, forKey: .logDraft)
        try values.encodeIfPresent(logTaskID, forKey: .logTaskID)
        if !logDraftImages.isEmpty { try values.encode(logDraftImages, forKey: .logDraftImages) }
        if !logDraftTags.isEmpty { try values.encode(logDraftTags, forKey: .logDraftTags) }
        try values.encode(deadlineDraft, forKey: .deadlineDraft)
    }

    static func deadlineItems(from text: String) -> [Todo] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Todo(title: $0) }
    }
}

public enum JournalDates {
    private static let cacheLock = NSLock()
    private static var cachedCalendar: Calendar?

    /// 日期计算在日历格子、排序里大量调用：缓存一份，系统时区变了才重建。
    public static var calendar: Calendar {
        let zone = TimeZone.current
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedCalendar, cachedCalendar.timeZone == zone { return cachedCalendar }
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = zone
        cachedCalendar = calendar
        return calendar
    }

    public static func key(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    public static func monthStart(_ date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)!.start
    }

    public static func date(for key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, key.count == 10,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              self.key(date) == key else { return nil }
        return date
    }

    /// `weekStart` 使用系统约定：1 = 周日，2 = 周一。
    public static func monthGrid(_ date: Date, weekStart: Int = 2) -> [Date] {
        let first = monthStart(date)
        let offset = (calendar.component(.weekday, from: first) - weekStart + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: first)!
        let dayCount = calendar.range(of: .day, in: .month, for: first)!.count
        let cellCount = ((offset + dayCount + 6) / 7) * 7
        return (0..<cellCount).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }
}

/// 每次可撤销的修改都会产生一个事件，界面据此显示带「撤销」的提示。
public struct ActionEvent: Equatable {
    public let id: Int
    public let name: String
}

struct JournalDocument: Codable {
    var version = 8
    var days: [String: DayEntry] = [:]
    var nextTaskNumber: Int?
    /// 标签注册表：显式创建的标签（可以是还没有任何内容的空标签）。用过的标签不需要在这里。
    var tags: [String]?
    /// 固定关联的待办（不计时）：没有明确指定、也不在专注计时时，新日志记到它名下。
    var pinnedTask: UUID?
    var boards: [Board]?
    var boardFavoriteOrder: [UUID]?
}

@MainActor
public final class JournalStore: ObservableObject {
    /// 缺失原图由同步器按可见内容请求，不在首次同步下载整座图库。
    var requestImage: ((String) -> Void)?
    var fetchImage: ((String) async throws -> Bool)?
    public static let imageAvailable = Notification.Name("TimelineImageAvailable")
    /// nil 表示尚未设置，可从旧版 Mac 的本机收藏迁移；空数组表示用户已清空收藏。
    @Published public internal(set) var boardFavoriteOrder: [UUID]?
    @Published public private(set) var boards: [Board] = [] {
        didSet { cachedBoardIndices = nil }
    }
    var cachedBoardIndices: [BoardOwner: Int]?
    @Published public private(set) var days: [String: DayEntry] = [:]
    @Published public private(set) var errorMessage: String?
    /// 只供逻辑判断，界面不读；不发布，免得每次保存都让所有窗口重算。
    public private(set) var lastSaved: Date?
    @Published public private(set) var isReadOnly = false
    @Published public private(set) var canUndoDelete = false
    @Published public private(set) var lastAction: ActionEvent?
    /// 正在专注计时的任务。专注期间，没有明确指定任务的日志都记到它名下。
    @Published public private(set) var focusTaskID: UUID?
    /// 专注暂停时保留任务状态，但普通日志不再自动关联到该任务。
    @Published public private(set) var focusPaused = false
    /// 显式创建的标签，包括还没有内容的空标签。
    @Published public internal(set) var tagRegistry: [String] = [] {
        didSet { cachedTagSummaries = nil }
    }
    /// 固定关联的待办（不计时）。读 `pinnedTask` 才会排除已删除的。
    @Published public internal(set) var pinnedTaskID: UUID?
    /// 最近删除（本机保留 30 天，不同步），新删的在前。
    @Published public internal(set) var recentlyDeleted: [DeletedItem] = []
    /// 工作板的历史版本，存在 `BoardHistory/` 里，用到时才读。
    lazy var boardHistory = BoardHistory(directory: directory.appendingPathComponent("BoardHistory", isDirectory: true), writesInBackground: writesInBackground)
    public let directory: URL
    /// 只供保存逻辑判断，界面不读；不发布，否则每次写盘完成清除标记时都会让所有窗口再重算一遍。
    public private(set) var hasPendingSave = false
    private var pendingSave: Task<Void, Never>?
    /// 写盘失败后的自动重试：依次等 `saveRetryDelays`，之后每隔最后一个间隔再试，直到写成功。
    private var saveRetry: Task<Void, Never>?
    private var saveRetryAttempt = 0
    /// 测试可以改短。
    var saveRetryDelays: [TimeInterval] = [2, 5, 15, 30]
    public let undoManager = UndoManager()
    /// 编码和写盘的串行队列。
    private lazy var writer = JournalWriter(fileURL: fileURL, backupsDirectory: backupsDirectory)
    /// 每次修改后的文档版本；写入完成时据此判断有没有更新的修改还没落盘。
    private var documentVersion = 0
    /// 为 true 时，修改后的保存在后台编码写入，不阻塞界面。应用开启它；测试默认同步，便于立即读取文件。
    /// `save()` 始终同步，并排在已提交的后台写入之后。
    public var writesInBackground = false
    private var deletedTodo: (task: Todo, date: Date, index: Int)?
    private var indexedTasks: [ScheduledTask]?
    /// 按 id / 编号定位任务，和 `indexedTasks` 一起失效。
    private var taskPositions: (byID: [UUID: Int], byNumber: [Int: Int])?
    private var cachedNoteTopics: [NoteTopic]?
    var cachedTagSummaries: [TagSummary]?
    private var cachedTimelineSegments: [UUID: LogTimelineSegment]?
    /// 每个任务的笔记条数：每一行的菜单都要显示，逐行扫描全部日志太慢。
    private var cachedNoteCounts: [UUID: Int]?
    /// 每天的有效专注秒数（按结束记录累加），月历每格都要用。
    private var cachedFocusByDay: [String: TimeInterval]?
    /// 按时间排好的全部日志（含专注记录）。笔记、标签、日志面板每次重绘都要用，日志变了才重建。
    private var cachedChronology: [LoggedLog]?
    private var cachedTaskSummaries: (key: String, value: [LogTaskSummary])?

    /// 输入草稿不影响汇总；只有日志或待办真的改变时才重新扫描历史。
    private func invalidateNotebookIndex(logsChanged: Bool, tasksChanged: Bool) {
        if logsChanged || tasksChanged { cachedNoteTopics = nil; cachedTagSummaries = nil; cachedTaskSummaries = nil }
        if logsChanged { cachedChronology = nil }
        if logsChanged { cachedTimelineSegments = nil; cachedNoteCounts = nil; cachedFocusByDay = nil }
    }

    /// 这一天记录到的有效专注时长（结束记录里的用时之和）。
    public func focusSeconds(on date: Date) -> TimeInterval {
        if cachedFocusByDay == nil {
            var totals: [String: TimeInterval] = [:]
            for (key, day) in days {
                let seconds = day.logs.filter { $0.focusMarker == "END" }.compactMap(\.focusElapsedSeconds).reduce(0, +)
                if seconds > 0 { totals[key] = seconds }
            }
            cachedFocusByDay = totals
        }
        return cachedFocusByDay?[JournalDates.key(date)] ?? 0
    }

    /// 等同 `notes(for:).count`，但只在日志变化后扫描一次。
    public func noteCount(for taskID: UUID) -> Int {
        if cachedNoteCounts == nil {
            var counts: [UUID: Int] = [:]
            for day in days.values {
                for log in day.logs where log.isNotebookEntry {
                    if let id = log.taskID { counts[id, default: 0] += 1 }
                }
            }
            cachedNoteCounts = counts
        }
        return cachedNoteCounts?[taskID] ?? 0
    }

    public func timelineSegments() -> [UUID: LogTimelineSegment] {
        if let cachedTimelineSegments { return cachedTimelineSegments }
        let result = LogTimelineSegment.segments(in: days.values.flatMap(\.logs))
        cachedTimelineSegments = result
        return result
    }
    private var indexedDeadlines: [String: [ScheduledTask]]?
    private var nextTaskNumber = 1
    public var backupsDirectory: URL { directory.appendingPathComponent("Backups", isDirectory: true) }
    public var fileURL: URL { directory.appendingPathComponent("journal.json") }
    public var backupURL: URL { directory.appendingPathComponent("journal.backup.json") }

    /// 默认的数据目录；`TIMELINE_DATA_DIR` 可以覆盖。
    public nonisolated static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["TIMELINE_DATA_DIR"], !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true) }
        if let override = environment["DAYLEAF_DATA_DIR"], !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Timeline", isDirectory: true)
    }

    public nonisolated static func migrateLegacyDirectory(applicationSupport: URL) throws -> Bool {
        let manager = FileManager.default
        let source = applicationSupport.appendingPathComponent("Dayleaf", isDirectory: true)
        let target = applicationSupport.appendingPathComponent("Timeline", isDirectory: true)
        let journal = source.appendingPathComponent("journal.json")
        guard manager.fileExists(atPath: journal.path) else { return false }
        if manager.fileExists(atPath: target.path) {
            guard manager.fileExists(atPath: target.appendingPathComponent("journal.json").path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            return false
        }
        let original = try Data(contentsOf: journal)
        let document = try JSONDecoder().decode(JournalDocument.self, from: original)
        guard (1...8).contains(document.version) else { throw CocoaError(.fileReadUnknown) }
        let staging = applicationSupport.appendingPathComponent(".Timeline-migration-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        for item in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            if item.lastPathComponent == "scheduler.sock" || item.lastPathComponent == "timeline.sock" { continue }
            try manager.copyItem(at: item, to: staging.appendingPathComponent(item.lastPathComponent))
        }
        guard try Data(contentsOf: staging.appendingPathComponent("journal.json")) == original,
              (try Data(contentsOf: journal)) == original else { throw CocoaError(.fileReadCorruptFile) }
        try manager.moveItem(at: staging, to: target)
        return true
    }

    /// `readOnlySnapshot`：纯只读打开，不创建目录、不写备份、不做迁移落盘，任何修改接口都不生效。
    /// 数据里的旧格式仍会在内存里按新模型解读，所以读到的内容和应用里一致。
    public init(directory: URL? = nil, readOnlySnapshot: Bool = false) {
        self.directory = directory ?? Self.defaultDirectory()
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 100
        do {
            if !readOnlySnapshot { try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true) }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                let document = try JSONDecoder().decode(JournalDocument.self, from: data)
                guard (1...8).contains(document.version) else {
                    throw CocoaError(.fileReadUnknown)
                }
                days = document.days
                tagRegistry = TagText.merge([], (document.tags ?? []).compactMap(TagText.normalize))
                pinnedTaskID = document.pinnedTask
                boards = document.boards ?? []
                boardFavoriteOrder = document.boardFavoriteOrder
                if !readOnlySnapshot { try data.write(to: backupURL, options: .atomic) }
                if document.version < 8, !boards.isEmpty {
                    if !readOnlySnapshot {
                        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
                        try data.write(to: backupsDirectory.appendingPathComponent("before-board-markdown-v\(document.version).json"), options: .atomic)
                    }
                    hasPendingSave = true
                }
                nextTaskNumber = max(document.nextTaskNumber ?? 1, (days.values.flatMap(\.todos).compactMap(\.number).max() ?? 0) + 1)
                if document.version < 6 {
                    // 旧版本里任务属于某一天；新模型里那一天就是它的截止日期。迁移前先单独留一份原文件。
                    if !readOnlySnapshot {
                        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
                        try data.write(to: backupsDirectory.appendingPathComponent("before-ddl-migration-v\(document.version).json"), options: .atomic)
                    }
                    adoptScheduledDayAsDeadline(in: &days)
                    hasPendingSave = true
                }
                if assignMissingNumbers(in: &days) { hasPendingSave = true }
            }
            if readOnlySnapshot { isReadOnly = true; hasPendingSave = false } else { loadRecentlyDeleted() }
        } catch {
            isReadOnly = true
            errorMessage = "无法读取日记，已停止写入以保护原文件。请在数据文件夹中检查 journal.json 和备份。\n\(error.localizedDescription)"
        }
        if hasPendingSave, !isReadOnly { save() }
    }

    func allocate(_ todo: Todo) -> Todo {
        var numbered = todo
        numbered.number = nextTaskNumber
        nextTaskNumber += 1
        return numbered
    }

    /// 没有截止日期的旧任务，用它原来所在的那一天作为截止日期（全天）。
    private func adoptScheduledDayAsDeadline(in days: inout [String: DayEntry]) {
        for (key, entry) in days {
            guard let date = JournalDates.date(for: key) else { continue }
            var updated = entry
            for index in updated.todos.indices where updated.todos[index].dueDate == nil {
                updated.todos[index].dueDate = date
                updated.todos[index].dueHasTime = false
            }
            days[key] = updated
        }
    }

    /// 给还没有编号的旧任务按「日期、清单顺序」补上永久编号，结果是确定的。
    @discardableResult
    private func assignMissingNumbers(in days: inout [String: DayEntry]) -> Bool {
        var changed = false
        for key in days.keys.sorted() {
            guard var entry = days[key] else { continue }
            for index in entry.todos.indices where entry.todos[index].number == nil {
                entry.todos[index].number = nextTaskNumber
                nextTaskNumber += 1
                changed = true
            }
            days[key] = entry
        }
        return changed
    }

    public func entry(for date: Date) -> DayEntry {
        days[JournalDates.key(date)] ?? DayEntry()
    }

    public func addTodo(_ title: String, on date: Date) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        change(date) { $0.todos.append(allocate(Todo(title: title))) }
    }

    public func toggleTodo(_ id: UUID, on date: Date, now: Date = Date()) {
        guard !isReadOnly else { return }
        var updated = days
        toggleTask(id, on: date, now: now, in: &updated)
        replaceDays(updated, action: "完成状态")
    }

    /// 放弃一个待办（不用再做了，但留着记录：编号、笔记、专注时长都在）；已经放弃的再调一次就恢复成未完成。
    /// 已经完成的待办不能放弃（先取消完成）。重复待办放弃的是这一次，下一次照常生成。
    @discardableResult
    public func dropTodo(_ id: UUID, on date: Date, now: Date = Date()) -> Bool {
        guard !isReadOnly, let task = tasks().first(where: { $0.id == id })?.task, !task.isDone else { return false }
        var updated = days
        toggleTask(id, on: date, now: now, dropping: true, in: &updated)
        replaceDays(updated, action: task.isDropped ? "恢复待办" : "放弃待办")
        return true
    }

    private func toggleTask(_ id: UUID, on date: Date, now: Date, dropping: Bool = false, in updated: inout [String: DayEntry]) {
        let key = JournalDates.key(date)
        guard let index = updated[key]?.todos.firstIndex(where: { $0.id == id }) else { return }
        let wasDropped = updated[key]!.todos[index].isDropped
        updated[key]!.todos[index].completed.toggle()
        // 完成 → 做完了；放弃 → dropping；再点一次（取消完成 / 恢复）→ 都回到未完成。
        updated[key]!.todos[index].dropped = updated[key]!.todos[index].completed && dropping
        // 从「已放弃」恢复的事项排到同一日期（或未设日期）的最后，不回到放弃前的位置。
        if wasDropped, !updated[key]!.todos[index].completed {
            let restored = updated[key]!.todos[index]
            let calendar = JournalDates.calendar
            let day = restored.timelineDate.map { calendar.startOfDay(for: $0) }
            let peers = updated.values.flatMap(\.todos).filter { other in
                other.id != restored.id && other.timelineDate.map { calendar.startOfDay(for: $0) } == day
            }
            if let last = peers.map(\.sortKey).max() { updated[key]!.todos[index].listPosition = max(last + 1, restored.sortKey) }
        }
        let task = updated[key]!.todos[index]
        var occurrence = task.repeatRule.nextDate(after: JournalDates.calendar.startOfDay(for: date), monthDay: task.repeatMonthDay)
        while let candidate = occurrence, candidate <= JournalDates.calendar.startOfDay(for: now) {
            occurrence = task.repeatRule.nextDate(after: candidate, monthDay: task.repeatMonthDay)
        }
        if task.completed, task.nextOccurrenceID == nil, let nextDate = occurrence {
            var next = allocate(task)
            next.id = UUID()
            next.completed = false
            next.dropped = false
            next.nextOccurrenceID = nil
            if let due = task.dueDate {
                let offset = JournalDates.calendar.dateComponents([.day], from: JournalDates.calendar.startOfDay(for: date), to: nextDate).day!
                next.dueDate = JournalDates.calendar.date(byAdding: .day, value: offset, to: due)
                next.startDate = task.timeRange.flatMap { JournalDates.calendar.date(byAdding: .day, value: offset, to: $0.start) }
            }
            updated[key]!.todos[index].nextOccurrenceID = next.id
            var nextEntry = updated[JournalDates.key(nextDate)] ?? DayEntry()
            nextEntry.todos.append(next)
            updated[JournalDates.key(nextDate)] = nextEntry
        }
    }

    public func renameTodo(_ id: UUID, title: String, on date: Date) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { deleteTodo(id, on: date); return }
        change(date) { entry in
            guard let index = entry.todos.firstIndex(where: { $0.id == id }) else { return }
            // 标题里写的 #标签 移到标签字段，和新建时一致。
            let parsed = TagText.extract(from: title)
            entry.todos[index].title = parsed.title
            entry.todos[index].tags = TagText.merge(entry.todos[index].tags, parsed.tags)
        }
    }

    public func deleteTodo(_ id: UUID, on date: Date) {
        guard !isReadOnly, let index = entry(for: date).todos.firstIndex(where: { $0.id == id }) else { return }
        deletedTodo = (entry(for: date).todos[index], date, index)
        canUndoDelete = true
        var updatedBoards = boards
        for boardIndex in updatedBoards.indices where updatedBoards[boardIndex].owner == .task(id) {
            updatedBoards[boardIndex].title = String(TaskText.rendered(entry(for: date).todos[index].title).characters)
        }
        undoManager.beginUndoGrouping()
        replaceBoards(updatedBoards, action: "删除任务")
        change(date, action: "删除任务") { $0.todos.remove(at: index) }
        undoManager.endUndoGrouping()
    }

    public func renameCalendarName(_ id: UUID, name: String, on date: Date) {
        change(date) { entry in
            guard let index = entry.todos.firstIndex(where: { $0.id == id }) else { return }
            entry.todos[index].calendarName = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    public func undoDelete() {
        guard let deletedTodo, locate(deletedTodo.task.id) == nil else { return }
        change(deletedTodo.date) { $0.todos.insert(deletedTodo.task, at: min(deletedTodo.index, $0.todos.count)) }
        self.deletedTodo = nil
        canUndoDelete = false
    }

    public func undo() {
        guard !isReadOnly else { return }
        undoManager.undo()
        canUndoDelete = false
        objectWillChange.send()
    }

    public func redo() {
        guard !isReadOnly else { return }
        undoManager.redo()
        objectWillChange.send()
    }

    public func setSummary(_ summary: String, on date: Date) {
        change(date, debounce: true) { $0.summary = summary }
    }

    public func setLogDraft(_ text: String, on date: Date) {
        change(date, debounce: true) { $0.logDraft = text }
    }

    public func setLogTask(_ id: UUID?, on date: Date) {
        change(date, debounce: true) { $0.logTaskID = id }
    }

    /// 草稿里的标签：加一个 / 去掉一个（不区分大小写，已有的不重复）。
    public func addDraftTag(_ tag: String, on date: Date) {
        guard let name = TagText.normalize(tag) else { return }
        change(date, debounce: true) { $0.logDraftTags = TagText.merge($0.logDraftTags, [name]) }
    }

    public func removeDraftTag(_ tag: String, on date: Date) {
        change(date, debounce: true) { $0.logDraftTags.removeAll { TagText.key($0) == TagText.key(tag) } }
    }

    /// 批量把日志关联到同一个待办（nil 取消关联），作为一次操作撤销。返回改动的条数。
    @discardableResult
    public func setLogTask(_ taskID: UUID?, forLogs ids: Set<UUID>) -> Int {
        guard !isReadOnly, !ids.isEmpty else { return 0 }
        let located = taskID.flatMap(locate)
        if taskID != nil, located == nil { return 0 }
        var updated = days
        var changed = 0
        for key in updated.keys {
            for index in updated[key]!.logs.indices where ids.contains(updated[key]!.logs[index].id) {
                var log = updated[key]!.logs[index]
                let title = located.map { String(TaskText.rendered($0.task.title).characters) }
                if log.taskID == located?.id, log.taskTitle == title { continue }
                log.taskID = located?.id
                log.taskTitle = title
                log.taskNumber = located?.task.number
                log.taskTags = located?.task.tags ?? []
                if log.taskID != updated[key]!.logs[index].taskID { updateFocusAssociation(&log) }
                updated[key]!.logs[index] = log
                changed += 1
            }
        }
        guard changed > 0 else { return 0 }
        replaceDays(updated, action: "批量关联待办")
        return changed
    }

    /// 批量删除日志，作为一次操作撤销（⌘Z 整批恢复）。返回删除的条数；专注计时的开始 / 结束记录也算日志，一并删除。
    @discardableResult
    public func deleteLogs(_ ids: Set<UUID>) -> Int {
        guard !isReadOnly, !ids.isEmpty else { return 0 }
        var updated = days
        var removed = 0
        for key in Array(updated.keys) {
            let before = updated[key]!.logs.count
            updated[key]!.logs.removeAll { ids.contains($0.id) }
            removed += before - updated[key]!.logs.count
            if !updated[key]!.hasContent { updated[key] = nil }
        }
        guard removed > 0 else { return 0 }
        replaceDays(updated, action: "删除日志")
        return removed
    }

    /// 批量给日志加、去标签，作为一次操作撤销。返回改动的条数。
    @discardableResult
    public func updateLogTags(add: [String] = [], remove: [String] = [], forLogs ids: Set<UUID>) -> Int {
        guard !isReadOnly, !ids.isEmpty else { return 0 }
        let added = add.compactMap(TagText.normalize)
        let removedKeys = Set(remove.compactMap(TagText.normalize).map(TagText.key))
        guard !added.isEmpty || !removedKeys.isEmpty else { return 0 }
        var updated = days
        var changed = 0
        for key in updated.keys {
            for index in updated[key]!.logs.indices where ids.contains(updated[key]!.logs[index].id) {
                let before = updated[key]!.logs[index].tags
                let kept = before.filter { !removedKeys.contains(TagText.key($0)) }
                let after = TagText.merge(kept, added)
                guard after != before else { continue }
                updated[key]!.logs[index].tags = after
                changed += 1
            }
        }
        guard changed > 0 else { return 0 }
        replaceDays(updated, action: "批量标签")
        return changed
    }

    /// 修改一条已经提交的日志所关联的任务（nil 取消关联），可撤销。历史日志也能补打标签。
    public func setLogTask(_ taskID: UUID?, forLog logID: UUID, on date: Date) {
        let located = taskID.flatMap(locate)
        change(date, action: "修改日志关联") { entry in
            guard let index = entry.logs.firstIndex(where: { $0.id == logID }) else { return }
            let previousTaskID = entry.logs[index].taskID
            if let located {
                entry.logs[index].taskID = located.id
                entry.logs[index].taskTitle = String(TaskText.rendered(located.task.title).characters)
                entry.logs[index].taskNumber = taskNumber(located.id, on: located.date)
                entry.logs[index].taskTags = located.task.tags
            } else {
                entry.logs[index].taskID = nil
                entry.logs[index].taskTitle = nil
                entry.logs[index].taskNumber = nil
                entry.logs[index].taskTags = []
            }
            if entry.logs[index].taskID != previousTaskID { updateFocusAssociation(&entry.logs[index]) }
        }
    }

    private func updateFocusAssociation(_ log: inout DailyLogEntry) {
        guard log.focusEvent == .note || !log.isFocusMarker else { return }
        log.focusEvent = log.taskID != nil && log.taskID == focusTaskID && !focusPaused ? .note : nil
    }

    @discardableResult
    public func commitLog(on date: Date, now: Date = Date(), linkDefault: Bool = true) throws -> LogCommand {
        guard !isReadOnly else { throw LogInputError.readOnly }
        let entry = entry(for: date)
        let images = entry.logDraftImages
        // 只贴了图片、没有文字时，作为一条随手记录提交。
        let command = entry.logDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !images.isEmpty
            ? LogCommand.entry(.note, "") : try LogCommand.parse(entry.logDraft)
        switch command {
        case .help, .summary, .filter: return command
        case .link(let number):
            var linkedID: UUID?
            if let number {
                guard let located = locate(number: number) else { throw LogInputError.unknownTask(number) }
                linkedID = located.id
            }
            change(date, debounce: true) { $0.logTaskID = linkedID; $0.logDraft = "" }
            return command
        case .entry: break
        }
        guard case let .entry(kind, rawBody) = command else { return command }
        // 正文开头的 #N 直接指向当天清单里的第 N 条任务；写了 / 命令却找不到时报错，纯文字则当作普通内容。
        var body = rawBody
        var inline: ScheduledTask?
        let split = LogCommand.splitTaskReference(rawBody)
        if let number = split.number {
            if let located = locate(number: number) {
                inline = located
                body = split.rest
            } else if entry.logDraft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
                throw LogInputError.unknownTask(number)
            }
        }
        // 明确指定的任务（正文里的 #N、手动选的关联）优先；都没有时，专注中的任务兜底。
        let explicit = inline ?? entry.logTaskID.flatMap(locate)
        if inline == nil, entry.logTaskID != nil, explicit == nil { throw LogInputError.missingTask }
        let linked = explicit ?? (linkDefault ? defaultLinkTask : nil)
        let title = linked.map { String(TaskText.rendered($0.task.title).characters) }
        // 只有明确指定的任务才会在空正文时借用标题，/done 也只完成明确指定的任务；专注兜底的关联不会替用户完成任务。
        let text = body.isEmpty ? (explicit != nil ? title ?? "" : "") : body
        guard !text.isEmpty || !images.isEmpty else { throw LogInputError.empty }
        var updated = days
        if kind == .done, let explicit, !explicit.task.completed {
            toggleTask(explicit.id, on: explicit.date, now: now, in: &updated)
        }
        let key = JournalDates.key(date)
        var day = updated[key] ?? DayEntry()
        day.logs.append(DailyLogEntry(createdAt: now, kind: kind, text: text, taskID: linked?.id, taskTitle: title,
                                     taskNumber: linked.flatMap { taskNumber($0.id, on: $0.date) },
                                     taskTags: linked?.task.tags ?? [], tags: entry.logDraftTags, images: images,
                                     focusEvent: !focusPaused && linked?.id != nil && linked?.id == focusTaskID ? .note : nil))
        day.logDraft = ""
        day.logTaskID = nil
        day.logDraftImages = []
        day.logDraftTags = []
        updated[key] = day
        replaceDays(updated, action: "添加日志")
        return command
    }

    public func updateLog(_ id: UUID, text: String, on date: Date) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, entry(for: date).logs.first(where: { $0.id == id })?.images.isEmpty != false { deleteLog(id, on: date); return }
        change(date) { entry in
            guard let index = entry.logs.firstIndex(where: { $0.id == id }) else { return }
            entry.logs[index].text = text
        }
    }

    public func deleteLog(_ id: UUID, on date: Date) {
        change(date, action: "删除日志") { $0.logs.removeAll { $0.id == id } }
    }

    public func applyReview(_ text: String, on date: Date, append: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        change(date) { entry in
            entry.summary = append && !entry.summary.isEmpty ? entry.summary + "\n\n" + text : text
        }
    }

    public func setDeadlineDraft(_ text: String, on date: Date) {
        change(date, debounce: true) { $0.deadlineDraft = text }
    }

    public func commitDeadline(on date: Date, dueDate: Date? = nil) {
        change(date) { entry in
            entry.todos.append(contentsOf: DayEntry.deadlineItems(from: entry.deadlineDraft).map { item in
                var task = allocate(item)
                task.dueDate = dueDate.map { JournalDates.calendar.startOfDay(for: $0) }
                return task
            })
            entry.deadlineDraft = ""
        }
    }

    public func toggleDeadline(_ id: UUID, on date: Date) {
        toggleTodo(id, on: date)
    }

    public func renameDeadline(_ id: UUID, title: String, on date: Date) {
        renameTodo(id, title: title, on: date)
    }

    public func deleteDeadline(_ id: UUID, on date: Date) {
        deleteTodo(id, on: date)
    }

    /// 逐行解析输入框草稿（识别日期、时间、提醒、重复），一次撤销即可还原。
    /// 识别出的日期是任务的截止日期；没写日期就是还没分配日期的任务。任务本身不属于某一天。
    @discardableResult
    public func commitDraft(on date: Date, now: Date = Date(), defaultDue: Bool = false, options: TaskCreationOptions = .init()) -> [ScheduledTask] {
        guard !isReadOnly else { return [] }
        let key = JournalDates.key(date)
        let lines = (days[key]?.deadlineDraft ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var updated = days
        var added: [ScheduledTask] = []
        for line in lines {
            let resolved = QuickAdd.parse(line, now: now).resolve(defaultDay: date, defaultDue: defaultDue)
            var entry = updated[key] ?? DayEntry()
            let numbered = allocate(options.applying(to: resolved.todo))
            entry.todos.append(numbered)
            updated[key] = entry
            added.append(ScheduledTask(date: date, task: numbered))
        }
        updated[key]?.deadlineDraft = ""
        if let entry = updated[key], !entry.hasContent { updated[key] = nil }
        replaceDays(updated, action: "添加待办")
        return added
    }

    /// 全局快速添加：识别日期、时间、提醒和重复；识别出的日期成为截止日期。
    @discardableResult
    public func addParsedTodo(_ text: String, on date: Date, now: Date = Date(), priority: TaskPriority = .normal, options: TaskCreationOptions? = nil) -> ScheduledTask? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isReadOnly, !text.isEmpty else { return nil }
        let resolved = QuickAdd.parse(text, now: now).resolve(defaultDay: date)
        var updated = days
        let key = JournalDates.key(date)
        var entry = updated[key] ?? DayEntry()
        var defaults = TaskCreationOptions()
        defaults.priority = priority
        let numbered = allocate((options ?? defaults).applying(to: resolved.todo))
        entry.todos.append(numbered)
        updated[key] = entry
        replaceDays(updated, action: "添加待办")
        return ScheduledTask(date: date, task: numbered)
    }

    /// 专注计时的开始、结束记录：写进当天终端日志，关联任务，但带「专注」标记，笔记视图不显示。
    /// `seconds` 大于 0 时同时累加到任务的专注时长，和日志一起作为一次操作（撤销时一并还原）。
    @discardableResult
    public func addFocusLog(_ text: String, taskID: UUID, now: Date = Date(), seconds: TimeInterval = 0,
                            fallback: (title: String, number: Int?)? = nil, event: FocusLogEvent? = nil,
                            goal: String? = nil, plannedSeconds: TimeInterval? = nil, endReason: String? = nil, minimumSeconds: TimeInterval? = nil) -> UUID? {
        // 任务已经删了（比如专注中把它删掉）：用开始时记下的名字写这条结束记录，时长没地方累加就不加。
        let located = locate(taskID)
        guard !isReadOnly, located != nil || fallback != nil else { return nil }
        var updated = days
        if seconds > 0, let located {
            let homeKey = JournalDates.key(located.date)
            if let index = updated[homeKey]?.todos.firstIndex(where: { $0.id == taskID }) {
                updated[homeKey]!.todos[index].focusSeconds += seconds
            }
        }
        let key = JournalDates.key(now)
        var entry = updated[key] ?? DayEntry()
        let log = DailyLogEntry(createdAt: now, kind: .note, text: text, taskID: taskID,
                                taskTitle: located.map { String(TaskText.rendered($0.task.title).characters) } ?? fallback?.title,
                                taskNumber: located?.task.number ?? fallback?.number, taskTags: located?.task.tags ?? [], focus: true,
                                focusEvent: event, focusGoal: goal, focusPlannedSeconds: plannedSeconds,
                                focusElapsedSeconds: event == .end ? seconds : nil, focusEndReason: endReason,
                                focusMinimumSeconds: event == .end ? minimumSeconds : nil)
        entry.logs.append(log)
        updated[key] = entry
        replaceDays(updated, action: "专注记录")
        return log.id
    }

    /// 太短的专注（比如手滑点了播放键）不留日志：把「开始专注」那条日志撤掉，不写「结束」，
    /// 用过的时间仍然累加到任务上。和日志的删除、时长的累加是一次操作，⌘Z 一起还原。
    public func discardShortFocus(startLogID: UUID?, taskID: UUID, seconds: TimeInterval, now: Date = Date()) {
        guard !isReadOnly else { return }
        var updated = days
        if seconds > 0, let located = locate(taskID) {
            let homeKey = JournalDates.key(located.date)
            if let index = updated[homeKey]?.todos.firstIndex(where: { $0.id == taskID }) {
                updated[homeKey]!.todos[index].focusSeconds += seconds
            }
        }
        if let startLogID {
            for key in updated.keys {
                guard let index = updated[key]?.logs.firstIndex(where: { $0.id == startLogID && $0.focus }) else { continue }
                updated[key]!.logs.remove(at: index)
                if !updated[key]!.hasContent { updated[key] = nil }
                break
            }
        }
        replaceDays(updated, action: "专注记录")
    }

    public func setFocusTask(_ id: UUID?) {
        if focusTaskID != id { focusTaskID = id }
        if id == nil { focusPaused = false }
    }

    public func setFocusPaused(_ paused: Bool) {
        guard focusTaskID != nil else { focusPaused = false; return }
        focusPaused = paused
    }

    /// 专注中的任务；任务已被删除时为 nil（日志照常记录，只是不再关联）。
    public var focusTask: ScheduledTask? { focusTaskID.flatMap(locate) }

    /// 固定关联的待办（不计时的「当前待办」）。已删除的不算；完成状态不影响固定。
    public var pinnedTask: ScheduledTask? { pinnedTaskID.flatMap(locate) }

    /// 没有明确指定任务时，新日志默认记到哪：专注中的任务优先，其次是固定关联的。
    public var defaultLinkTask: ScheduledTask? { focusPaused ? nil : (focusTask ?? pinnedTask) }

    /// 固定 / 取消固定一个待办。任何仍存在的待办都能固定；返回是否生效。固定不进撤销栈。
    @discardableResult
    public func pinTask(_ id: UUID?) -> Bool {
        guard !isReadOnly else { return false }
        if let id {
            guard locate(id) != nil else { return false }
            guard pinnedTaskID != id else { return true }
            pinnedTaskID = id
        } else {
            guard pinnedTaskID != nil else { return true }
            pinnedTaskID = nil
        }
        registryChanged()
        return true
    }

    /// 关联任务的笔记，按时间从早到晚；专注开始、反馈和结束仅在日志中显示。
    public func notes(for taskID: UUID) -> [LoggedLog] {
        logs(linkedTo: [taskID]).filter { $0.log.isNotebookEntry }
    }

    /// 全局快速记录：不经过当天的输入草稿，直接追加一条日志。
    /// 关联哪个待办：明确传入的 `taskID` > 正文开头写的 `#N` > （`linkDefault` 为 true 时）专注中的 / 固定关联的待办。
    /// `linkDefault: false` 表示明确要「不关联」，比如在笔记本里写一条直接记录。
    @discardableResult
    public func quickLog(_ text: String, images: [String] = [], taskID: UUID? = nil, linkDefault: Bool = true, tags: [String] = [], allowInlineTaskReference: Bool = true, on date: Date, now: Date = Date()) throws -> LogCommand {
        try quickLogEntry(text, images: images, taskID: taskID, linkDefault: linkDefault, tags: tags, allowInlineTaskReference: allowInlineTaskReference, on: date, now: now).command
    }

    /// 同 `quickLog`，同时返回写入的那条日志（命令不是普通记录时为 nil），界面据此告诉用户最终关联到了哪个待办。
    @discardableResult
    public func quickLogEntry(_ text: String, images: [String] = [], taskID: UUID? = nil, linkDefault: Bool = true, tags: [String] = [], allowInlineTaskReference: Bool = true, on date: Date, now: Date = Date(), focusEvent: FocusLogEvent? = nil, focusGoal: String? = nil, focusPlannedSeconds: TimeInterval? = nil) throws -> (command: LogCommand, entry: DailyLogEntry?) {
        guard !isReadOnly else { throw LogInputError.readOnly }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !images.isEmpty
            ? LogCommand.entry(.note, "") : try LogCommand.parse(text)
        guard case .entry(let kind, var body) = command else { return (command, nil) }
        // 没有明确传入任务时，开头的 #N 指向第 N 号任务（后面没有内容时当作普通文字，不吞掉）。
        var inline: ScheduledTask?
        let split = LogCommand.splitTaskReference(body)
        if allowInlineTaskReference, taskID == nil, let number = split.number, !split.rest.isEmpty, let located = locate(number: number) {
            inline = located
            body = split.rest
        }
        guard !body.isEmpty || !images.isEmpty else { throw LogInputError.empty }
        var updated = days
        let key = JournalDates.key(date)
        var entry = updated[key] ?? DayEntry()
        let linked = taskID.flatMap(locate) ?? inline ?? (linkDefault ? defaultLinkTask : nil)
        let created = DailyLogEntry(createdAt: now, kind: kind, text: body,
                                    taskID: linked?.id, taskTitle: linked.map { String(TaskText.rendered($0.task.title).characters) },
                                    taskNumber: linked?.task.number, taskTags: linked?.task.tags ?? [],
                                    tags: TagText.merge([], tags.compactMap(TagText.normalize)), images: images,
                                    focusEvent: focusEvent ?? (!focusPaused && linked?.id != nil && linked?.id == focusTaskID ? .note : nil),
                                    focusGoal: focusGoal, focusPlannedSeconds: focusPlannedSeconds)
        entry.logs.append(created)
        updated[key] = entry
        replaceDays(updated, action: "添加日志")
        return (command, created)
    }

    /// 截止日期早于 `date` 且未完成的任务数量。
    public func unfinishedCount(before date: Date) -> Int {
        let start = JournalDates.calendar.startOfDay(for: date)
        return tasks().filter { !$0.task.completed && $0.task.effectiveDeadline.map { $0 <= start } == true }.count
    }

    /// 把已逾期未完成任务的截止日期改到 `date`（全天），作为一次操作撤销。返回改动的数量。
    @discardableResult
    public func rolloverUnfinished(to date: Date) -> Int {
        guard !isReadOnly else { return 0 }
        let target = JournalDates.calendar.startOfDay(for: date)
        let late = tasks().filter { !$0.task.completed && $0.task.effectiveDeadline.map { $0 <= target } == true }
        guard !late.isEmpty else { return 0 }
        var updated = days
        for item in late {
            let key = JournalDates.key(item.date)
            guard let index = updated[key]?.todos.firstIndex(where: { $0.id == item.id }) else { continue }
            updated[key]!.todos[index].dueDate = target
            updated[key]!.todos[index].dueHasTime = false
            updated[key]!.todos[index].startDate = nil
        }
        replaceDays(updated, action: "移到今天")
        return late.count
    }

    public func overdueCount(now: Date = Date()) -> Int {
        tasks(filter: .overdue, now: now).count
    }

    // MARK: - 笔记（按任务汇总日志）

    public struct NoteTopic: Identifiable {
        public let id: UUID
        public let number: Int?
        public let title: String
        public let count: Int
        public let imageCount: Int
        public let lastActivity: Date
        public let completed: Bool
        public let dropped: Bool
        public let deleted: Bool
        public let dueDate: Date?
        public let focusSeconds: TimeInterval
        public let tags: [String]
    }

    /// 至少有一条日志关联的任务，最近有笔记的排在前面。
    public func noteTopics() -> [NoteTopic] {
        if let cachedNoteTopics { return cachedNoteTopics }
        var info: [UUID: (count: Int, images: Int, latest: Date, title: String, number: Int?)] = [:]
        for day in days.values {
            for log in day.logs where log.isNotebookEntry {
                guard let id = log.taskID else { continue }
                let previous = info[id]
                info[id] = ((previous?.count ?? 0) + 1, (previous?.images ?? 0) + log.images.count, max(previous?.latest ?? .distantPast, log.createdAt),
                            log.taskTitle ?? previous?.title ?? "", log.taskNumber ?? previous?.number)
            }
        }
        let result = info.map { id, value in
            let located = locate(id)
            return NoteTopic(id: id, number: located?.task.number ?? value.number,
                             title: located.map { String(TaskText.rendered($0.task.title).characters) } ?? value.title,
                             count: value.count, imageCount: value.images, lastActivity: value.latest,
                             completed: located?.task.completed ?? false, dropped: located?.task.isDropped ?? false, deleted: located == nil, dueDate: located?.task.dueDate,
                             focusSeconds: located?.task.focusSeconds ?? 0, tags: located?.task.tags ?? [])
        }.sorted { $0.lastActivity > $1.lastActivity }
        cachedNoteTopics = result
        return result
    }

    /// 某个任务的笔记主题：有笔记就是 `noteTopics()` 里那一项；还没有笔记、但任务还在，就给一个 0 条的主题，
    /// 这样从清单里「打开笔记」总能落到这个任务的页面上，直接开始写。任务已删除且没有笔记时为 nil。
    public func noteTopic(for id: UUID) -> NoteTopic? {
        if let existing = noteTopics().first(where: { $0.id == id }) { return existing }
        guard let located = locate(id) else { return nil }
        return NoteTopic(id: id, number: located.task.number, title: String(TaskText.rendered(located.task.title).characters),
                         count: 0, imageCount: 0, lastActivity: .distantPast,
                         completed: located.task.completed, dropped: located.task.isDropped, deleted: false,
                         dueDate: located.task.dueDate, focusSeconds: located.task.focusSeconds, tags: located.task.tags)
    }

    /// 一组可以左右翻看的图片：每张带上它来自哪条笔记（日期 + 正文开头）。
    public struct GalleryImage: Equatable {
        public let name: String
        public let logID: UUID
        public let caption: String
    }

    /// 和这条日志属于同一个任务的所有笔记里的图片，按时间顺序；日志没有关联任务时，就是它自己的图片。
    public func galleryImages(around log: DailyLogEntry) -> [GalleryImage] {
        let logs: [LoggedLog]
        if let id = log.taskID {
            logs = log.isNotebookEntry ? notes(for: id) : self.logs(linkedTo: [id])
        } else {
            logs = allLogs(includeFocus: true).filter { $0.log.id == log.id }
        }
        return Self.gallery(of: logs)
    }

    /// 一组笔记里的所有图片（按传入的顺序）。
    public static func gallery(of logs: [LoggedLog]) -> [GalleryImage] {
        logs.flatMap { item -> [GalleryImage] in
            let text = String(TaskText.rendered(item.log.text).characters).trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt = text.count > 40 ? String(text.prefix(40)) + "…" : text
            let caption = item.key + (excerpt.isEmpty ? "" : " · " + excerpt)
            return item.log.images.map { GalleryImage(name: $0, logID: item.log.id, caption: caption) }
        }
    }

    // MARK: - 按任务筛选日志

    public struct LoggedLog: Identifiable {
        public let key: String
        public let date: Date
        public let log: DailyLogEntry
        public var id: UUID { log.id }
    }

    public struct LogTaskSummary: Identifiable {
        public let id: UUID
        public let title: String
        public let number: Int?
        public let date: Date?
        public let count: Int
        public let deleted: Bool
    }

    /// 全部日志（跨日期），按时间从早到晚；`includeFocus` 为 false 时不含专注计时的开始、结束记录。
    public func allLogs(includeFocus: Bool = false) -> [LoggedLog] {
        let all = chronology()
        return includeFocus ? all : all.filter { !$0.log.focus }
    }

    /// 按日期、同一天内按时间排好的全部日志；只在日志变化后重建一次。
    private func chronology() -> [LoggedLog] {
        if let cachedChronology { return cachedChronology }
        let result = days.keys.sorted().flatMap { key -> [LoggedLog] in
            guard let date = JournalDates.date(for: key), let day = days[key] else { return [] }
            return day.logs.sorted { $0.createdAt < $1.createdAt }.map { LoggedLog(key: key, date: date, log: $0) }
        }
        cachedChronology = result
        return result
    }

    /// 与指定任务相关的全部日志（跨日期），按时间从早到晚。
    public func logs(linkedTo ids: Set<UUID>) -> [LoggedLog] {
        guard !ids.isEmpty else { return [] }
        return chronology().filter { $0.log.taskID.map(ids.contains) == true }
    }

    /// 可用于筛选的任务：`date` 当天清单里的任务，以及所有被日志关联过的任务（含已删除的）。
    public func logTaskSummaries(on date: Date) -> [LogTaskSummary] {
        let key = JournalDates.key(date)
        if let cachedTaskSummaries, cachedTaskSummaries.key == key { return cachedTaskSummaries.value }
        let value = computeLogTaskSummaries()
        cachedTaskSummaries = (key, value)
        return value
    }

    private func computeLogTaskSummaries() -> [LogTaskSummary] {
        var counts: [UUID: (count: Int, latest: Date, title: String)] = [:]
        for day in days.values {
            for log in day.logs {
                guard let id = log.taskID else { continue }
                let previous = counts[id]
                counts[id] = ((previous?.count ?? 0) + 1, max(previous?.latest ?? .distantPast, log.createdAt), log.taskTitle ?? previous?.title ?? "")
            }
        }
        var result: [LogTaskSummary] = []
        var seen = Set<UUID>()
        for item in sortedTasks() where !item.task.completed {
            seen.insert(item.id)
            result.append(LogTaskSummary(id: item.id, title: String(TaskText.rendered(item.task.title).characters), number: item.task.number,
                                         date: item.date, count: counts[item.id]?.count ?? 0, deleted: false))
        }
        let others = counts.filter { !seen.contains($0.key) }.sorted { $0.value.latest > $1.value.latest }
        for (id, info) in others {
            let located = locate(id)
            result.append(LogTaskSummary(id: id, title: located.map { String(TaskText.rendered($0.task.title).characters) } ?? info.title,
                                         number: located.flatMap { taskNumber($0.id, on: $0.date) }, date: located?.date,
                                         count: info.count, deleted: located == nil))
        }
        return result
    }

    // MARK: - 日志图片

    public var imagesDirectory: URL { directory.appendingPathComponent("Images", isDirectory: true) }

    public func imageURL(_ name: String) -> URL {
        let url = imagesDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { requestImage?(name) }
        return url
    }

    /// 保存已处理好的图片数据，返回文件名。
    public func storeImage(_ data: Data, fileExtension: String) throws -> String {
        guard !isReadOnly else { throw LogInputError.readOnly }
        return try OriginalImage.store(data, extension: fileExtension, directory: imagesDirectory)
    }

    /// 原图校验、摘要和磁盘写入都在后台完成，避免大照片阻塞打字和动画。
    public func storeOriginalImage(_ data: Data) async throws -> String {
        guard !isReadOnly else { throw LogInputError.readOnly }
        let directory = imagesDirectory
        return try await Task.detached(priority: .userInitiated) {
            guard let ext = OriginalImage.fileExtension(for: data) else { throw CocoaError(.fileReadUnknown) }
            return try OriginalImage.store(data, extension: ext, directory: directory)
        }.value
    }

    public func addDraftImage(_ name: String, on date: Date) {
        change(date, debounce: true) { if !$0.logDraftImages.contains(name) { $0.logDraftImages.append(name) } }
    }

    public func removeDraftImage(_ name: String, on date: Date) {
        change(date, debounce: true) { $0.logDraftImages.removeAll { $0 == name } }
    }

    /// 尚未做文字识别的图片文件名。
    public func imagesMissingText() -> [String] {
        var seen = Set<String>()
        return days.values.flatMap { $0.logs }.flatMap { log in
            log.images.filter { log.imageText[$0] == nil && seen.insert($0).inserted }
        }
    }

    /// 写入识别结果；不进入撤销栈，也不改变其他内容。
    public func setImageText(_ text: String, image name: String) {
        setImageTexts([name: text])
    }

    /// 一次写入多张图片的识别结果：只扫描一遍日志、发布一次，避免大量图片排队时逐张刷新所有窗口。
    public func setImageTexts(_ texts: [String: String]) {
        guard !isReadOnly, !texts.isEmpty else { return }
        var updated = days
        var changed = false
        for (key, entry) in days {
            for index in entry.logs.indices {
                for name in entry.logs[index].images {
                    guard let text = texts[name], entry.logs[index].imageText[name] != text else { continue }
                    updated[key]!.logs[index].imageText[name] = text
                    changed = true
                }
            }
        }
        guard changed else { return }
        invalidateNotebookIndex(logsChanged: true, tasksChanged: false)
        days = updated
        hasPendingSave = true
        scheduleSave()
    }

    /// 导出为文件夹：journal.json 加上被引用的全部图片。
    public func prepareImageExport() async throws {
        for name in referencedImageNames(in: days).sorted() {
            if FileManager.default.fileExists(atPath: imagesDirectory.appendingPathComponent(name).path) { continue }
            guard try await fetchImage?(name) == true else { throw ImageExportError.unavailable }
        }
    }

    public func exportFolder(to folder: URL) throws {
        let names = referencedImageNames(in: days)
        // 按需下载后，备份不能静默漏掉还在云端的原图。
        guard names.allSatisfy({ FileManager.default.fileExists(atPath: imagesDirectory.appendingPathComponent($0).path) }) else {
            throw ImageExportError.unavailable
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try export(to: folder.appendingPathComponent("journal.json"))
        guard !names.isEmpty else { return }
        let target = folder.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in names where FileManager.default.fileExists(atPath: imageURL(name).path) {
            let destination = target.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: imageURL(name), to: destination)
        }
    }

    /// 从导出的文件夹复制图片，已存在的同名文件保持不动。返回复制的数量。
    @discardableResult
    public func importImages(from folder: URL) throws -> Int {
        let source = folder.appendingPathComponent("Images", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return 0 }
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        var copied = 0
        for file in files where !FileManager.default.fileExists(atPath: imageURL(file.lastPathComponent).path) {
            try FileManager.default.copyItem(at: file, to: imageURL(file.lastPathComponent))
            copied += 1
        }
        return copied
    }

    private func referencedImageNames(in days: [String: DayEntry]) -> Set<String> {
        Set(days.values.flatMap { $0.logs.flatMap(\.images) + $0.logDraftImages }).union(imagesInRecentlyDeleted)
    }

    /// 删除不再被当前数据、每日快照和上次启动备份引用的图片，之后撤销或恢复备份仍然安全。
    public func unusedImageNames() -> [String] {
        Self.unusedImageNames(imagesDirectory: imagesDirectory, backupURL: backupURL,
                              backupsDirectory: backupsDirectory, keeping: referencedImageNames(in: days))
    }

    nonisolated private static func unusedImageNames(imagesDirectory: URL, backupURL: URL,
                                                     backupsDirectory: URL, keeping: Set<String>) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path), !files.isEmpty else { return [] }
        var keep = keeping
        var documents = [backupURL]
        documents += (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in documents where url.pathExtension == "json" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for name in files where !keep.contains(name) && text.contains(name) { keep.insert(name) }
        }
        return files.filter { !keep.contains($0) }
    }

    /// 云端清理也必须保护本机草稿、最近删除和可恢复备份中的图片。
    func retainedImagesForSync() async -> Set<String>? {
        let keep = referencedImageNames(in: days)
        let backup = backupURL, backups = backupsDirectory
        return await Task.detached(priority: .utility) {
            var result = keep
            let manager = FileManager.default
            var documents: [URL] = manager.fileExists(atPath: backup.path) ? [backup] : []
            if manager.fileExists(atPath: backups.path) {
                guard let files = try? manager.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil) else { return nil as Set<String>? }
                documents += files.filter { $0.pathExtension == "json" }
            }
            // 提取备份中的文件名，包含从未下载到本机的远端原图。
            // 一次解析一份备份，避免每张图片都重新搜索整份备份文本。
            func collect(_ value: Any) {
                if let object = value as? [String: Any] {
                    for (key, child) in object {
                        if ["images", "logDraftImages"].contains(key), let names = child as? [String] { result.formUnion(names) }
                        else { collect(child) }
                    }
                } else if let array = value as? [Any] { for child in array { collect(child) } }
            }
            for document in documents {
                guard let data = try? Data(contentsOf: document), let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
                collect(value)
            }
            return result
        }.value
    }

    /// 启动维护只在后台读取、扫描备份；回到主线程后重新检查引用。
    /// 扫描期间有保存就跳过本次清理，避免用过期的备份快照删除图片。
    @discardableResult
    public func removeUnusedImagesInBackground(olderThan age: TimeInterval = 3600, now: Date = Date()) async -> Int {
        guard !isReadOnly else { return 0 }
        let savedAt = lastSaved
        let images = imagesDirectory, backup = backupURL, backups = backupsDirectory
        let keep = referencedImageNames(in: days)
        let unused = await Task.detached(priority: .utility) {
            Self.unusedImageNames(imagesDirectory: images, backupURL: backup, backupsDirectory: backups, keeping: keep)
        }.value
        guard !Task.isCancelled, lastSaved == savedAt, !isReadOnly else { return 0 }
        let current = referencedImageNames(in: days)
        return removeImageFiles(unused.filter { !current.contains($0) }, olderThan: age, now: now)
    }

    @discardableResult
    public func removeUnusedImages(olderThan age: TimeInterval = 3600, now: Date = Date()) -> Int {
        guard !isReadOnly else { return 0 }
        return removeImageFiles(unusedImageNames(), olderThan: age, now: now)
    }

    private func removeImageFiles(_ names: [String], olderThan age: TimeInterval, now: Date) -> Int {
        var removed = 0
        for name in names {
            let url = imageURL(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(modified) >= age else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// 同步保存并确认落盘：退出、关窗口、需要立即知道结果的操作用它。
    public func save() {
        guard !isReadOnly else { return }
        pendingSave?.cancel()
        pendingSave = nil
        documentVersion += 1
        finishSave(writer.writeNow(documentSnapshot, version: documentVersion), version: documentVersion)
    }

    /// 修改后的保存：开启后台写入时不阻塞界面，否则同 `save()`。
    private func persist() {
        guard writesInBackground else { save(); return }
        guard !isReadOnly else { return }
        pendingSave?.cancel()
        pendingSave = nil
        documentVersion += 1
        let version = documentVersion
        writer.write(documentSnapshot, version: version) { [weak self] error in
            MainActor.assumeIsolated { self?.finishSave(error, version: version) }
        }
    }

    /// 写盘失败后过一会儿自动再试：磁盘腾出空间、权限修好后不用用户再动手。
    private func scheduleSaveRetry() {
        guard saveRetry == nil, !isReadOnly, let last = saveRetryDelays.last else { return }
        let delay = saveRetryAttempt < saveRetryDelays.count ? saveRetryDelays[saveRetryAttempt] : last
        saveRetryAttempt += 1
        saveRetry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self else { return }
            self.saveRetry = nil
            guard self.errorMessage != nil, !self.isReadOnly else { return }
            self.persist()
        }
    }

    /// 等所有后台写入完成（测试用）。
    public func waitForPendingWrites() { writer.waitUntilIdle() }

    private func finishSave(_ error: Error?, version: Int) {
        if let error {
            errorMessage = "保存失败，当前修改仍保留在内存中。请释放磁盘空间或检查权限后重试。\n\(error.localizedDescription)"
            scheduleSaveRetry()
            return
        }
        saveRetry?.cancel()
        saveRetry = nil
        saveRetryAttempt = 0
        lastSaved = Date()
        // 期间又有修改：等那次写入完成再清除标记。值没变就不赋值，免得通知所有观察的窗口。
        guard version == documentVersion else { return }
        if hasPendingSave { hasPendingSave = false }
        if errorMessage != nil { errorMessage = nil }
    }

    public func export(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(documentSnapshot).write(to: url, options: .atomic)
    }

    public func tasks(matching query: String = "", filter: AgendaFilter = .all, now: Date = Date()) -> [ScheduledTask] {
        if indexedTasks == nil {
            indexedTasks = days.flatMap { key, entry -> [ScheduledTask] in
                guard let date = JournalDates.date(for: key) else { return [] }
                return entry.todos.map { ScheduledTask(date: date, task: $0) }
            }.sorted { $0.date == $1.date ? $0.task.title < $1.task.title : $0.date < $1.date }
        }
        guard !query.isEmpty || filter != .all else { return indexedTasks! }
        // 「#标签」只找带这个标签（含子标签）的待办；普通词也会匹配标签名。
        let tag = TagText.searchTag(query)
        return indexedTasks!.filter { item in
            guard filter.includes(item.task, now: now) else { return false }
            if let tag { return item.task.tags.contains { TagText.matches($0, query: tag) } }
            return query.isEmpty || item.task.title.localizedStandardContains(query) || item.task.calendarName.localizedStandardContains(query)
                || item.task.tags.contains { $0.localizedStandardContains(query) }
        }
    }

    public var calendarDeadlines: [String: [ScheduledTask]] {
        if indexedDeadlines == nil {
            indexedDeadlines = Dictionary(grouping: tasks().filter { $0.task.dueDate != nil }) {
                JournalDates.key($0.task.timelineDate!)
            }.mapValues { $0.sorted(by: ScheduledTask.listOrder) }
        }
        return indexedDeadlines!
    }

    private func invalidateTaskIndex() {
        indexedTasks = nil
        taskPositions = nil
        indexedDeadlines = nil
        // 只有删除才取消固定，完成或放弃后仍可继续往该任务记录日志。
        if let pinnedTaskID, locate(pinnedTaskID) == nil { self.pinnedTaskID = nil }
    }

    private func taskIndex() -> (tasks: [ScheduledTask], byID: [UUID: Int], byNumber: [Int: Int]) {
        let all = tasks()
        if let taskPositions { return (all, taskPositions.byID, taskPositions.byNumber) }
        var byID: [UUID: Int] = [:], byNumber: [Int: Int] = [:]
        byID.reserveCapacity(all.count)
        for (index, item) in all.enumerated() {
            if byID[item.id] == nil { byID[item.id] = index }
            if let number = item.task.number, byNumber[number] == nil { byNumber[number] = index }
        }
        taskPositions = (byID, byNumber)
        return (all, byID, byNumber)
    }

    public func locate(_ id: UUID) -> ScheduledTask? {
        let index = taskIndex()
        return index.byID[id].map { index.tasks[$0] }
    }

    /// 任务的永久编号（`on` 仅为兼容旧调用）。
    public func taskNumber(_ id: UUID, on date: Date) -> Int? {
        locate(id)?.task.number
    }

    /// 按永久编号找任务。
    public func locate(number: Int) -> ScheduledTask? {
        let index = taskIndex()
        return index.byNumber[number].map { index.tasks[$0] }
    }

    /// 全部任务，按截止时间从早到晚；没有截止日期的排在最后，同一时间按编号。手动拖过位置的任务按它的手动位置排。
    public func sortedTasks() -> [ScheduledTask] {
        tasks().sorted(by: ScheduledTask.listOrder)
    }

    /// 手动调整顺序：`ids` 是这些任务想要的从上到下的顺序（通常是清单里同一分组的任务）。
    /// 做法是把它们原有的排序键按新顺序重新分配，所以只改变它们彼此的先后，不会挤到别的分组里。一次操作，可撤销。
    public func reorderTasks(_ ids: [UUID]) {
        guard !isReadOnly, ids.count > 1 else { return }
        let located = ids.compactMap { locate($0) }
        guard located.count == ids.count else { return }
        var keys: [Double] = []
        for key in located.map(\.task.sortKey).sorted() {
            // 键相同（同一天、没有日期）时拉开一点，否则新顺序会被编号顺序盖掉。
            keys.append(keys.last.map { max(key, $0 + 0.001) } ?? key)
        }
        var updated = days
        for (item, key) in zip(located, keys) {
            let dayKey = JournalDates.key(item.date)
            guard let index = updated[dayKey]?.todos.firstIndex(where: { $0.id == item.id }) else { continue }
            updated[dayKey]!.todos[index].listPosition = key
        }
        replaceDays(updated, action: "调整顺序")
    }

    /// 把任务拖到某一天（nil = 未设日期）的某个位置：改日期和排序作为一次操作，⌘Z 一起撤销。
    /// `order` 是目标分组里放下后的完整顺序（含被拖的任务）。
    public func moveTask(_ id: UUID, to day: Date?, order: [UUID]) {
        guard !isReadOnly, let located = locate(id) else { return }
        let calendar = JournalDates.calendar
        let sameDay = located.task.timelineDate.map { calendar.startOfDay(for: $0) } == day.map { calendar.startOfDay(for: $0) }
        undoManager.beginUndoGrouping()
        if !sameDay { setDeadline(id, to: day) }
        reorderTasks(order)
        undoManager.setActionName("移动任务")
        undoManager.endUndoGrouping()
        lastAction = ActionEvent(id: (lastAction?.id ?? 0) + 1, name: "移动任务")
    }

    /// 设置或清除截止日期。`keepingTime` 为 true 时保留原来的时分，只换日期。
    public func setDeadline(_ id: UUID, to date: Date?, keepingTime: Bool = true) {
        guard !isReadOnly, let located = locate(id) else { return }
        let calendar = JournalDates.calendar
        var due: Date?
        var hasTime = false
        if let date {
            if keepingTime, let range = located.task.timeRange {
                let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: range.start), to: calendar.startOfDay(for: date)).day ?? 0
                due = calendar.date(byAdding: .day, value: offset, to: range.end)
                hasTime = true
            } else if keepingTime, located.task.dueHasTime, let old = located.task.dueDate {
                let time = calendar.dateComponents([.hour, .minute], from: old)
                due = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: date)
                hasTime = true
            } else {
                due = calendar.startOfDay(for: date)
            }
        }
        updateTodo(id, scheduledDate: located.date, dueDate: due, dueHasTime: hasTime,
                   reminderMinutes: located.task.reminderMinutes, repeatRule: located.task.repeatRule)
    }

    public func calendarTasks(on date: Date, includeScheduled: Bool = false) -> [ScheduledTask] {
        let scheduled = includeScheduled ? entry(for: date).todos.map { ScheduledTask(date: date, task: $0) } : []
        let identifiers = Set(scheduled.map(\.id))
        let due = (calendarDeadlines[JournalDates.key(date)] ?? []).filter { !identifiers.contains($0.id) }
        return scheduled + due
    }

    public func moveTodo(_ id: UUID, to destination: Date) {
        guard !isReadOnly, let located = locate(id), JournalDates.key(located.date) != JournalDates.key(destination) else { return }
        updateTodo(id, scheduledDate: destination, dueDate: located.task.dueDate, dueHasTime: located.task.dueHasTime,
                   reminderMinutes: located.task.reminderMinutes, repeatRule: located.task.repeatRule)
    }

    public func placeTodo(_ id: UUID, on destination: Date, relativeTo anchorID: UUID? = nil, after: Bool = false, debounce: Bool = false) {
        guard !isReadOnly, anchorID != id, let located = locate(id) else { return }
        let sourceKey = JournalDates.key(located.date)
        let targetKey = JournalDates.key(destination)
        guard var source = days[sourceKey], let sourceIndex = source.todos.firstIndex(where: { $0.id == id }) else { return }
        if let anchorID, days[targetKey]?.todos.contains(where: { $0.id == anchorID }) != true { return }
        let task = source.todos.remove(at: sourceIndex)
        var updated = days
        updated[sourceKey] = source.hasContent ? source : nil
        var target = updated[targetKey] ?? DayEntry()
        if let anchorID, let anchorIndex = target.todos.firstIndex(where: { $0.id == anchorID }) {
            target.todos.insert(task, at: anchorIndex + (after ? 1 : 0))
        } else {
            target.todos.append(task)
        }
        updated[targetKey] = target
        replaceDays(updated, action: sourceKey == targetKey ? "调整顺序" : "移动任务", debounce: debounce)
    }

    public func updateTodo(_ id: UUID, scheduledDate: Date, dueDate: Date?, dueHasTime: Bool, reminderMinutes: Int?, repeatRule: RepeatRule, calendarName: String? = nil, tags: [String]? = nil, priority: TaskPriority? = nil, startDate: Date?? = nil) {
        guard !isReadOnly, let located = locate(id) else { return }
        // 未传 startDate 时移动日期保留时间段；显式 .some(nil) 切回单个截止时刻。
        if let start = startDate ?? nil, dueDate == nil || !dueHasTime || start >= dueDate! { return }
        let sourceKey = JournalDates.key(located.date)
        guard var source = days[sourceKey], let index = source.todos.firstIndex(where: { $0.id == id }) else { return }
        var task = source.todos[index]
        if let priority { task.priority = priority }
        if let calendarName { task.calendarName = calendarName.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        if let tags { task.tags = TagText.merge([], tags.compactMap(TagText.normalize)) }
        let oldRange = task.timeRange
        task.dueDate = dueDate.map { dueHasTime ? $0 : JournalDates.calendar.startOfDay(for: $0) }
        if let explicit = startDate {
            task.startDate = explicit
        } else if dueHasTime, let end = task.dueDate, let oldRange {
            task.startDate = end.addingTimeInterval(-oldRange.duration)
        } else { task.startDate = nil }
        task.dueHasTime = dueDate != nil && dueHasTime
        task.reminderMinutes = dueDate == nil ? nil : reminderMinutes
        task.repeatRule = repeatRule
        if repeatRule == .monthly, task.repeatMonthDay == nil { task.repeatMonthDay = JournalDates.calendar.component(.day, from: scheduledDate) }
        var updated = days
        let targetKey = JournalDates.key(scheduledDate)
        if sourceKey == targetKey {
            source.todos[index] = task
            updated[sourceKey] = source
        } else {
            source.todos.remove(at: index)
            updated[sourceKey] = source.hasContent ? source : nil
            var target = updated[targetKey] ?? DayEntry()
            target.todos.append(task)
            updated[targetKey] = target
        }
        replaceDays(updated, action: "安排任务")
    }

    public func setPriority(_ priority: TaskPriority, for id: UUID) {
        guard !isReadOnly, let located = locate(id), located.task.priority != priority else { return }
        var updated = days
        let key = JournalDates.key(located.date)
        guard let index = updated[key]?.todos.firstIndex(where: { $0.id == id }) else { return }
        updated[key]!.todos[index].priority = priority
        replaceDays(updated, action: "修改优先级")
    }

    public func backups() -> [BackupRecord] {
        var urls = (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        if FileManager.default.fileExists(atPath: backupURL.path) { urls.append(backupURL) }
        return urls.filter { $0.pathExtension == "json" }.map {
            BackupRecord(url: $0, date: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.date > $1.date }
    }

    public func inspectBackup(_ url: URL) throws -> BackupPreview {
        let document = try readBackup(url)
        return BackupPreview(dayCount: document.days.count, taskCount: document.days.values.reduce(0) { $0 + $1.todos.count },
                             summaryCount: document.days.values.filter { !$0.summary.isEmpty }.count,
                             logCount: document.days.values.reduce(0) { $0 + $1.logs.count })
    }

    public func restore(from url: URL) throws {
        let document = try readBackup(url)
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let current = isReadOnly && FileManager.default.fileExists(atPath: fileURL.path)
            ? try Data(contentsOf: fileURL) : try JSONEncoder().encode(documentSnapshot)
        let recovery = backupsDirectory.appendingPathComponent("before-restore-\(JournalDates.key(Date()))-\(UUID().uuidString).json")
        try current.write(to: recovery, options: .atomic)
        isReadOnly = false
        // 旧版本的备份同样要迁移：所在日期成为截止日期，并补上永久编号。编号只增不减，不会和现有日志里的引用冲突。
        var restored = document.days
        if document.version < 6 { adoptScheduledDayAsDeadline(in: &restored) }
        tagRegistry = TagText.merge(tagRegistry, (document.tags ?? []).compactMap(TagText.normalize))
        nextTaskNumber = max(nextTaskNumber, document.nextTaskNumber ?? 1, (restored.values.flatMap(\.todos).compactMap(\.number).max() ?? 0) + 1)
        assignMissingNumbers(in: &restored)
        undoManager.beginUndoGrouping()
        replaceBoards(document.boards ?? [], action: "恢复备份")
        setBoardFavoriteOrder(document.boardFavoriteOrder ?? [])
        replaceDays(restored, action: "恢复备份", force: true)
        undoManager.endUndoGrouping()
        save()
        if let errorMessage { throw NSError(domain: "Timeline", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage]) }
    }

    private func readBackup(_ url: URL) throws -> JournalDocument {
        let document = try JSONDecoder().decode(JournalDocument.self, from: Data(contentsOf: url))
        guard (1...8).contains(document.version), document.days.keys.allSatisfy({ JournalDates.date(for: $0) != nil }) else { throw CocoaError(.fileReadCorruptFile) }
        let ids = document.days.values.flatMap { $0.todos.map(\.id) }
        guard Set(ids).count == ids.count else { throw CocoaError(.fileReadCorruptFile) }
        let logIDs = document.days.values.flatMap { $0.logs.map(\.id) }
        guard Set(logIDs).count == logIDs.count else { throw CocoaError(.fileReadCorruptFile) }
        let boards = document.boards ?? []
        guard Set(boards.map(\.id)).count == boards.count else { throw CocoaError(.fileReadCorruptFile) }
        return document
    }

    private func registerUndo(_ previous: [String: DayEntry], replacing updated: [String: DayEntry], action: String) {
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        if grouping { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { store in
            var restored = store.days
            for key in Set(previous.keys).union(updated.keys) {
                let before = previous[key] ?? DayEntry()
                let after = updated[key] ?? DayEntry()
                var current = restored[key] ?? DayEntry()
                if before.todos != after.todos, current.todos == after.todos { current.todos = before.todos }
                if before.summary != after.summary, current.summary == after.summary { current.summary = before.summary }
                if before.deadlineDraft != after.deadlineDraft, current.deadlineDraft == after.deadlineDraft { current.deadlineDraft = before.deadlineDraft }
                if before.logs != after.logs, current.logs == after.logs { current.logs = before.logs }
                if before.logDraft != after.logDraft, current.logDraft == after.logDraft { current.logDraft = before.logDraft }
                if before.logTaskID != after.logTaskID, current.logTaskID == after.logTaskID { current.logTaskID = before.logTaskID }
                if before.logDraftImages != after.logDraftImages, current.logDraftImages == after.logDraftImages { current.logDraftImages = before.logDraftImages }
                if before.logDraftTags != after.logDraftTags, current.logDraftTags == after.logDraftTags { current.logDraftTags = before.logDraftTags }
                restored[key] = current.hasContent ? current : nil
            }
            store.replaceDays(restored, action: action, force: true)
        }
        undoManager.setActionName(action)
        if grouping {
            undoManager.endUndoGrouping()
            lastAction = ActionEvent(id: (lastAction?.id ?? 0) + 1, name: action)
        }
    }

    private func replaceDays(_ updated: [String: DayEntry], action: String, force: Bool = false, debounce: Bool = false) {
        guard !isReadOnly, force || updated != days else { return }
        registerUndo(days, replacing: updated, action: action)
        let tasksChanged = Set(days.keys).union(updated.keys).contains(where: { (days[$0]?.todos ?? []) != (updated[$0]?.todos ?? []) })
        let logsChanged = Set(days.keys).union(updated.keys).contains { (days[$0]?.logs ?? []) != (updated[$0]?.logs ?? []) }
        invalidateNotebookIndex(logsChanged: logsChanged, tasksChanged: tasksChanged)
        if tasksChanged || logsChanged { trackDeletions(from: days, to: updated, keys: Set(days.keys).union(updated.keys)) }
        days = updated
        if tasksChanged { invalidateTaskIndex() }
        hasPendingSave = true
        if debounce { scheduleSave() } else { persist() }
    }

    func change(_ date: Date, debounce: Bool = false, action: String = "修改事项", mutation: (inout DayEntry) -> Void) {
        guard !isReadOnly else { return }
        let key = JournalDates.key(date)
        var entry = days[key] ?? DayEntry()
        mutation(&entry)
        guard entry != (days[key] ?? DayEntry()) else { return }
        var updated = days
        updated[key] = entry.hasContent ? entry : nil
        if !debounce { registerUndo(days, replacing: updated, action: action) }
        let tasksChanged = entry.todos != (days[key]?.todos ?? [])
        let logsChanged = entry.logs != (days[key]?.logs ?? [])
        invalidateNotebookIndex(logsChanged: logsChanged, tasksChanged: tasksChanged)
        if tasksChanged || logsChanged { trackDeletions(from: days, to: updated, keys: [key]) }
        days = updated
        if tasksChanged { invalidateTaskIndex() }
        hasPendingSave = true
        if debounce {
            scheduleSave()
        } else {
            persist()
        }
    }

    /// 标签注册表变了：落盘（注册表不进撤销栈）。
    func registryChanged() {
        hasPendingSave = true
        persist()
    }

    private var documentSnapshot: JournalDocument {
        JournalDocument(days: days, nextTaskNumber: nextTaskNumber, tags: tagRegistry.isEmpty ? nil : tagRegistry,
                        pinnedTask: pinnedTaskID, boards: boards.isEmpty ? nil : boards, boardFavoriteOrder: boardFavoriteOrder)
    }

    /// 同步用的内容快照：值类型，可以交给后台线程整理。
    var syncContent: SyncContent {
        SyncContent(days: days, boards: boards, tags: tagRegistry, pinnedTask: pinnedTaskID, nextTaskNumber: nextTaskNumber, boardFavoriteOrder: boardFavoriteOrder)
    }

    /// 用合并了其他设备修改的内容整体替换当前数据。远端修改不进撤销栈，已有的撤销记录也作废，
    /// 免得撤销时把别的设备刚同步过来的内容一起退回去。
    func applySyncContent(_ content: SyncContent) {
        guard !isReadOnly, content != syncContent else { return }
        let tasksChanged = Set(days.keys).union(content.days.keys).contains { (days[$0]?.todos ?? []) != (content.days[$0]?.todos ?? []) }
        let logsChanged = Set(days.keys).union(content.days.keys).contains { (days[$0]?.logs ?? []) != (content.days[$0]?.logs ?? []) }
        undoManager.removeAllActions()
        deletedTodo = nil
        canUndoDelete = false
        invalidateNotebookIndex(logsChanged: logsChanged, tasksChanged: tasksChanged)
        if tasksChanged || logsChanged { trackDeletions(from: days, to: content.days, keys: Set(days.keys).union(content.days.keys)) }
        days = content.days
        if boards != content.boards {
            // 别的设备改过的工作板：先把本机这一版存进历史，冲突合并或覆盖后都能找回来。
            recordBoardVersions(from: boards, to: content.boards, force: true)
            trackBoardDeletions(from: boards, to: content.boards)
            boards = content.boards
            cachedTagSummaries = nil
        }
        if tagRegistry != content.tags { tagRegistry = content.tags }
        nextTaskNumber = max(nextTaskNumber, content.nextTaskNumber)
        if pinnedTaskID != content.pinnedTask { pinnedTaskID = content.pinnedTask }
        if boardFavoriteOrder != content.boardFavoriteOrder { boardFavoriteOrder = content.boardFavoriteOrder }
        if tasksChanged { invalidateTaskIndex() }
        hasPendingSave = true
        persist()
    }

    func replaceBoards(_ updated: [Board], action: String, debounce: Bool = false) {
        guard !isReadOnly, updated != boards else { return }
        let previous = boards
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        if grouping { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { store in store.replaceBoards(previous, action: action) }
        undoManager.setActionName(action)
        if grouping { undoManager.endUndoGrouping() }
        recordBoardVersions(from: previous, to: updated)
        trackBoardDeletions(from: previous, to: updated)
        boards = updated
        if previous.map(\.owner) != updated.map(\.owner) || previous.map(\.archived) != updated.map(\.archived) {
            cachedTagSummaries = nil
        }
        hasPendingSave = true
        if debounce { scheduleSave() } else { persist() }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            self?.persist()
        }
    }
}

// MARK: - 标签改名、合并、删除

extension JournalStore {
    /// 把标签 `tag` 里属于 `old`（含它的子标签）的部分换成 `new`：`论文` → `研究` 时，`论文/方法` 变成 `研究/方法`；不相干的原样返回。
    public static func renamedTag(_ tag: String, from old: String, to new: String) -> String {
        let parts = tag.split(separator: "/").map(String.init)
        let oldParts = old.split(separator: "/").map { TagText.key(String($0)) }
        guard parts.count >= oldParts.count, zip(parts, oldParts).allSatisfy({ TagText.key($0) == $1 }) else { return tag }
        return ([new] + parts.dropFirst(oldParts.count)).joined(separator: "/")
    }

    /// 这个标签或它的子标签。
    public static func isTag(_ tag: String, under name: String) -> Bool {
        let key = TagText.key(tag), root = TagText.key(name)
        return key == root || key.hasPrefix(root + "/")
    }

    /// 改名：所有待办、日志（含快照里的任务标签）、草稿、注册表里的这个标签（连同子标签）都换成新名字。
    /// 新名字已经存在就是**合并**：两边的内容汇到一起，重复的去掉。一次 ⌘Z 全部恢复（包括注册表）。返回新名字；不合法返回 nil。
    @discardableResult
    public func renameTag(_ old: String, to raw: String) -> String? {
        guard !isReadOnly, let new = TagText.normalize(raw), allTags().contains(where: { $0.id == TagText.key(old) }) else { return nil }
        guard new != old else { return new }
        let map = { (tags: [String]) in TagText.merge([], tags.map { Self.renamedTag($0, from: old, to: new) }) }
        var updated = days
        for key in Array(updated.keys) {
            var day = updated[key]!
            for index in day.todos.indices { day.todos[index].tags = map(day.todos[index].tags) }
            for index in day.logs.indices {
                day.logs[index].tags = map(day.logs[index].tags)
                day.logs[index].taskTags = map(day.logs[index].taskTags)
            }
            day.logDraftTags = map(day.logDraftTags)
            updated[key] = day
        }
        var updatedBoards = boards
        for index in updatedBoards.indices {
            if case .tag(let tag) = updatedBoards[index].owner, !updatedBoards[index].archived {
                updatedBoards[index].owner = .tag(Self.renamedTag(tag, from: old, to: new))
            }
        }
        applyTagChange(days: updated, registry: map(tagRegistry), boards: updatedBoards, action: "重命名标签")
        return new
    }

    /// 删除标签（连同子标签）：从所有待办、日志、草稿、注册表里去掉，**内容本身都保留**。一次 ⌘Z 全部恢复。返回受影响的待办和日志条数。
    @discardableResult
    public func deleteTag(_ name: String) -> Int {
        guard !isReadOnly, allTags().contains(where: { $0.id == TagText.key(name) }) else { return 0 }
        let strip = { (tags: [String]) in tags.filter { !Self.isTag($0, under: name) } }
        var updated = days
        var touched = 0
        for key in Array(updated.keys) {
            var day = updated[key]!
            for index in day.todos.indices where day.todos[index].tags.contains(where: { Self.isTag($0, under: name) }) {
                day.todos[index].tags = strip(day.todos[index].tags)
                touched += 1
            }
            for index in day.logs.indices {
                let before = day.logs[index]
                day.logs[index].tags = strip(before.tags)
                day.logs[index].taskTags = strip(before.taskTags)
                if day.logs[index].tags != before.tags { touched += 1 }
            }
            day.logDraftTags = strip(day.logDraftTags)
            updated[key] = day
        }
        var updatedBoards = boards
        for index in updatedBoards.indices {
            if case .tag(let tag) = updatedBoards[index].owner, Self.isTag(tag, under: name) {
                updatedBoards[index].archived = true
            }
        }
        applyTagChange(days: updated, registry: strip(tagRegistry), boards: updatedBoards, action: "删除标签")
        return touched
    }

    /// 数据和注册表一起改，作为一次撤销。
    private func applyTagChange(days updated: [String: DayEntry], registry: [String], boards updatedBoards: [Board], action: String) {
        undoManager.beginUndoGrouping()
        replaceBoards(updatedBoards, action: action)
        replaceDays(updated, action: action)
        if registry != tagRegistry {
            registerRegistryUndo(tagRegistry, action: action)
            tagRegistry = registry
            registryChanged()
        }
        undoManager.setActionName(action)
        undoManager.endUndoGrouping()
    }

    private func registerRegistryUndo(_ previous: [String], action: String) {
        undoManager.registerUndo(withTarget: self) { store in
            let current = store.tagRegistry
            store.tagRegistry = previous
            store.registryChanged()
            store.registerRegistryUndo(current, action: action)
        }
    }
}
