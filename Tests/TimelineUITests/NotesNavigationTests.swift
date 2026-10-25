import AppKit
import XCTest
import TimelineCore
@testable import Timeline

@MainActor
final class NotesNavigationTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func defaults() -> UserDefaults {
        let suite = "notes-nav-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist"))
        }
        return defaults
    }

    private func makeStore() throws -> (JournalStore, ScheduledTask, ScheduledTask) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        let a = try XCTUnwrap(store.addParsedTodo("读论文 #论文", on: day))
        let b = try XCTUnwrap(store.addParsedTodo("写周报", on: day))
        _ = try store.quickLog("甲", taskID: a.id, on: day, now: day.addingTimeInterval(1))
        _ = try store.quickLog("乙", taskID: b.id, on: day, now: day.addingTimeInterval(2))
        return (store, a, b)
    }

    func testPositionSurvivesAFreshLaunch() throws {
        let defaults = defaults()
        let (_, a, _) = try makeStore()
        let first = NotesNavigation(defaults: defaults)
        first.open(task: a.id)
        first.query = "论文"
        first.chapterView = false
        let second = NotesNavigation(defaults: defaults)
        XCTAssertEqual(second.selection, a.id, "重启后还在上次的任务")
        XCTAssertEqual(second.query, "论文", "搜索词也在，不用重新搜")
        XCTAssertFalse(second.chapterView)
        first.open(tag: "论文")
        let third = NotesNavigation(defaults: defaults)
        XCTAssertNil(third.selection)
        XCTAssertEqual(third.tagSelection, "论文")
        XCTAssertTrue(NotesNavigation(defaults: nil).chapterView, "第一次用，默认按待办看")
    }

    func testValidateKeepsAValidPositionAndFallsBackWhenItIsGone() throws {
        let (store, a, b) = try makeStore()
        let nav = NotesNavigation()
        nav.open(task: b.id)
        nav.validate(in: store)
        XCTAssertEqual(nav.selection, b.id, "位置有效就原样保留，不跳到别处")
        nav.open(task: UUID())
        nav.validate(in: store)
        XCTAssertEqual(nav.selection, store.noteTopics().first?.id, "任务没了就退回最近有笔记的")
        nav.open(tag: "论文")
        nav.validate(in: store)
        XCTAssertEqual(nav.tagSelection, "论文")
        nav.open(tag: "已经不存在的标签")
        nav.validate(in: store)
        XCTAssertNil(nav.tagSelection)
        XCTAssertNotNil(nav.selection)
        _ = a
    }

    func testReopeningRestoresWhereYouLeftAndAnExplicitTargetOverridesIt() throws {
        let (store, a, b) = try makeStore()
        let nav = NotesNavigation()
        let controller = NotesWindowController(nav: nav)
        Self.keepAlive += [controller]
        controller.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        nav.open(task: b.id)
        nav.query = "周报"
        let window = try XCTUnwrap(controller.window)
        controller.close()
        XCTAssertFalse(controller.isVisible)

        controller.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(nav.selection, b.id, "再打开还是关闭时看的那个任务")
        XCTAssertEqual(nav.query, "周报", "搜索词还在")

        controller.close()
        controller.show(store: store, taskID: a.id, reveal: { _ in }, openDay: { _ in })
        XCTAssertEqual(nav.selection, a.id, "明确指定任务时才跳过去")
        controller.close()
        controller.show(store: store, taskID: nil, tag: "论文", reveal: { _ in }, openDay: { _ in })
        XCTAssertEqual(nav.tagSelection, "论文")
        XCTAssertNil(nav.selection)
        controller.close()
    }

    func testOutlineAndCollapsedChaptersAreRememberedPerTag() {
        let suite = defaults()
        let nav = NotesNavigation(defaults: suite)
        XCTAssertTrue(nav.showOutline, "目录默认显示")
        nav.showOutline = false
        XCTAssertFalse(NotesNavigation(defaults: suite).showOutline, "目录开关会被记住")

        // 待办章节默认折叠；直接记录默认展开。
        XCTAssertTrue(nav.isCollapsed(tag: "论文", chapter: "A"))
        XCTAssertFalse(nav.isCollapsed(tag: "论文", chapter: NotesNavigation.directChapter))
        nav.setCollapsed(false, tag: "论文", chapter: "A")
        XCTAssertFalse(nav.isCollapsed(tag: "论文", chapter: "A"))
        XCTAssertTrue(nav.isCollapsed(tag: "论文", chapter: "B"))
        XCTAssertTrue(nav.isCollapsed(tag: "读书", chapter: "A"), "每个标签各自折叠")
        XCTAssertFalse(nav.isCollapsed(tag: "论文".uppercased(), chapter: "A"))
        nav.setCollapsed(true, tag: "论文", chapter: "A")
        XCTAssertTrue(nav.isCollapsed(tag: "论文", chapter: "A"))
        nav.setCollapsed(true, tag: "论文", chapter: NotesNavigation.directChapter)
        XCTAssertTrue(nav.isCollapsed(tag: "论文", chapter: NotesNavigation.directChapter))
    }

}

@MainActor
final class DraftKeepingTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func makeStore() throws -> (JournalStore, ScheduledTask, ScheduledTask) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JournalStore(directory: directory)
        return (store, try XCTUnwrap(store.addParsedTodo("读论文", on: day)), try XCTUnwrap(store.addParsedTodo("写周报", on: day)))
    }

    func testNoteDraftsAreKeptPerTaskAndPerTagAndClearedOnlyOnSubmitOrWhenEmpty() throws {
        let (_, a, b) = try makeStore()
        let nav = NotesNavigation()
        let keyA = NotesNavigation.draftKey(task: a.id), keyB = NotesNavigation.draftKey(task: b.id)
        let tagKey = NotesNavigation.draftKey(tag: "论文")
        nav.updateDraft(keyA) { $0.text = "写到一半的想法" }
        nav.updateDraft(keyB) { $0.text = "另一个"; $0.images = ["x.png"] }
        nav.updateDraft(tagKey) { $0.text = "笔记本里的"; $0.link = a.id }
        nav.open(task: b.id)
        nav.open(tag: "论文")
        nav.open(task: a.id)
        XCTAssertEqual(nav.draft(keyA).text, "写到一半的想法", "切到别处再回来，草稿还在")
        XCTAssertEqual(nav.draft(keyB).images, ["x.png"], "图片也在")
        XCTAssertEqual(nav.draft(tagKey).link, a.id, "标签页里选的关联待办也在")
        XCTAssertEqual(NotesNavigation.draftKey(tag: "论文"), NotesNavigation.draftKey(tag: "论文".uppercased()), "标签不区分大小写")
        nav.updateDraft(keyA) { $0.text = "   " }
        XCTAssertTrue(nav.draft(keyA).isEmpty)
        XCTAssertNil(nav.drafts[keyA], "空白草稿不占位")
        nav.clearDraft(keyB)
        XCTAssertTrue(nav.draft(keyB).isEmpty)
    }

    func testDraftsSurviveClosingAndReopeningTheNotesWindow() throws {
        let (store, a, _) = try makeStore()
        let nav = NotesNavigation()
        let controller = NotesWindowController(nav: nav)
        Self.keepAlive.append(controller)
        controller.show(store: store, taskID: a.id, reveal: { _ in }, openDay: { _ in })
        nav.updateDraft(NotesNavigation.draftKey(task: a.id)) { $0.text = "去别的应用复制点东西" }
        controller.close()
        controller.show(store: store, taskID: nil, reveal: { _ in }, openDay: { _ in })
        XCTAssertEqual(nav.draft(NotesNavigation.draftKey(task: a.id)).text, "去别的应用复制点东西")
        controller.close()
    }

    func testQuickCaptureDraftIsHeldByTheModelUntilSubmitted() {
        let model = QuickCaptureModel()
        XCTAssertFalse(model.hasDraft)
        model.text = "  "
        XCTAssertFalse(model.hasDraft, "只有空白不算草稿")
        model.text = "复制来的一大段"
        model.images = ["a.png"]
        model.tags = ["论文"]
        XCTAssertTrue(model.hasDraft)
        model.mode = .log
        XCTAssertEqual(model.text, "复制来的一大段", "切换模式不丢")
        model.clearDraft()
        XCTAssertFalse(model.hasDraft)
        XCTAssertTrue(model.images.isEmpty && model.tags.isEmpty)
        model.tags = ["仅标签"]
        XCTAssertTrue(model.hasDraft, "只选了标签也算草稿")
    }

    func testDraftKeepsTheChosenLinkAndNoLinkChoice() {
        let nav = NotesNavigation()
        let id = UUID()
        nav.updateDraft("tag:论文") { $0.link = id }
        XCTAssertEqual(nav.draft("tag:论文").link, id)
        nav.updateDraft("tag:论文") { $0.link = nil; $0.unlinked = true }
        XCTAssertTrue(nav.draft("tag:论文").unlinked, "「这条不关联」也算草稿的一部分，不会被当成空草稿丢掉")
        nav.updateDraft("tag:论文") { $0.unlinked = false }
        XCTAssertTrue(nav.draft("tag:论文").isEmpty)
    }
}
