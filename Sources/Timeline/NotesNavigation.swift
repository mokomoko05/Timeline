import Foundation
import TimelineCore

/// 笔记输入框里没发送的内容：文字、图片、可选关联的待办。
struct NoteDraft: Equatable {
    var text = ""
    var images: [String] = []
    var link: UUID?
    /// 明确选了「不关联」（专注中 / 固定关联时，默认会自动关联）。
    var unlinked = false
    /// 在输入框里用 `#` 额外选的标签。
    var tags: [String] = []

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty && link == nil && !unlinked && tags.isEmpty }
}

/// 笔记窗口停在哪里：选中的任务或标签、搜索词、标签页按待办还是按日期看。
/// 每次变化都存进偏好，所以关掉窗口甚至退出应用再打开，都回到上次的位置，不用重新搜索。
@MainActor
final class NotesNavigation: ObservableObject {
    private let defaults: UserDefaults?
    private let prefix: String

    @Published var selection: UUID? { didSet { if selection != oldValue { defaults?.set(selection?.uuidString, forKey: prefix + ".task") } } }
    @Published var tagSelection: String? { didSet { if tagSelection != oldValue { defaults?.set(tagSelection, forKey: prefix + ".tag") } } }
    @Published var query: String { didSet { if query != oldValue { defaults?.set(query, forKey: prefix + ".query") } } }
    @Published var chapterView: Bool { didSet { if chapterView != oldValue { defaults?.set(chapterView, forKey: prefix + ".chapters") } } }
    /// 标签页右侧的目录（章节列表）显示与否。
    @Published var showOutline: Bool { didSet { if showOutline != oldValue { defaults?.set(showOutline, forKey: prefix + ".outline") } } }
    /// 折叠起来的章节（只在应用运行期间保留）：`标签|章节` 的键。
    @Published var collapsed: Set<String> = []
    /// 每个任务、每个标签各有一份没发送的草稿（只在应用运行期间保留）：切到别处、关掉窗口、去别的应用复制东西，回来都还在。
    @Published private(set) var drafts: [String: NoteDraft] = [:]

    static func draftKey(task id: UUID) -> String { "task:" + id.uuidString }
    static func draftKey(tag: String) -> String { "tag:" + TagText.key(tag) }

    static func collapseKey(tag: String, chapter: String) -> String { TagText.key(tag) + "|" + chapter }

    func isCollapsed(tag: String, chapter: String) -> Bool { collapsed.contains(Self.collapseKey(tag: tag, chapter: chapter)) }

    func setCollapsed(_ value: Bool, tag: String, chapter: String) {
        let key = Self.collapseKey(tag: tag, chapter: chapter)
        if value { collapsed.insert(key) } else { collapsed.remove(key) }
    }

    func draft(_ key: String) -> NoteDraft { drafts[key] ?? NoteDraft() }

    func updateDraft(_ key: String, _ change: (inout NoteDraft) -> Void) {
        var value = draft(key)
        change(&value)
        if value.isEmpty { drafts[key] = nil } else if drafts[key] != value { drafts[key] = value }
    }

    func clearDraft(_ key: String) { drafts[key] = nil }

    /// `defaults` 为 nil 时只在内存里（测试、一次性的视图）。
    init(defaults: UserDefaults? = nil, prefix: String = "notes.nav") {
        self.defaults = defaults
        self.prefix = prefix
        selection = defaults?.string(forKey: prefix + ".task").flatMap(UUID.init(uuidString:))
        tagSelection = defaults?.string(forKey: prefix + ".tag")
        query = defaults?.string(forKey: prefix + ".query") ?? ""
        chapterView = defaults?.object(forKey: prefix + ".chapters") as? Bool ?? true
        showOutline = defaults?.object(forKey: prefix + ".outline") as? Bool ?? true
    }

    func open(task id: UUID) {
        if tagSelection != nil { tagSelection = nil }
        if selection != id { selection = id }
    }
    func open(tag: String) {
        if selection != nil { selection = nil }
        if tagSelection != tag { tagSelection = tag }
    }

    /// 上次停留的任务被删除、或标签不存在了，就退回到最近有笔记的任务；停留的位置还有效就原样保留。
    func validate(in store: JournalStore) {
        if let tag = tagSelection, !store.allTags().contains(where: { $0.id == TagText.key(tag) }) { tagSelection = nil }
        // 选中的任务还在（哪怕还没有笔记）就保留，否则退回最近有笔记的任务。
        if let id = selection, store.noteTopic(for: id) == nil { selection = nil }
        if selection == nil, tagSelection == nil, let first = store.noteTopics().first?.id { selection = first }
    }
}
