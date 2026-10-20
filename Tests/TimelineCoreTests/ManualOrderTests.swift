import XCTest
@testable import TimelineCore

@MainActor
final class ManualOrderTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!
    private var tomorrow: Date { JournalDates.calendar.date(byAdding: .day, value: 1, to: day)! }

    private func makeStore() -> (JournalStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (JournalStore(directory: directory), directory)
    }

    private func numbers(_ store: JournalStore) -> [Int] { store.sortedTasks().compactMap(\.task.number) }

    func testReorderingTasksWithTheSameDeadlineOverridesNumberOrder() throws {
        let (store, _) = makeStore()
        for title in ["甲", "乙", "丙", "丁"] { store.addTodo(title, on: day) }
        XCTAssertEqual(numbers(store), [1, 2, 3, 4], "没有截止日期：按编号")
        let ids = numbers(store).compactMap { store.locate(number: $0)?.id }
        store.reorderTasks([ids[2], ids[0], ids[3], ids[1]])
        XCTAssertEqual(numbers(store), [3, 1, 4, 2])
        store.reorderTasks([ids[3], ids[2], ids[1], ids[0]])
        XCTAssertEqual(numbers(store), [4, 3, 2, 1], "可以反复调整")
    }

    func testReorderingOnlyPermutesTheGivenTasksAndLeavesOtherGroupsAlone() throws {
        let (store, _) = makeStore()
        store.addParsedTodo("今天 A", on: day)
        store.addParsedTodo("明天 B", on: day)
        for title in ["无日期 C", "无日期 D"] { store.addTodo(title, on: day) }
        let before = numbers(store)
        let c = try XCTUnwrap(store.locate(number: 3)), d = try XCTUnwrap(store.locate(number: 4))
        store.reorderTasks([d.id, c.id])
        let after = numbers(store)
        XCTAssertEqual(after.suffix(2), [4, 3], "无日期这一组里 D 跑到 C 前面")
        XCTAssertEqual(Array(after.prefix(before.count - 2)), Array(before.prefix(before.count - 2)), "别的任务相对顺序不变")
        XCTAssertEqual(Set(store.sortedTasks().map(\.id)).count, 4)
    }

    func testManualOrderPersistsAndChangingTheDeadlineResetsIt() throws {
        let (store, directory) = makeStore()
        for title in ["甲", "乙", "丙"] { store.addTodo(title, on: day) }
        let ids = numbers(store).compactMap { store.locate(number: $0)?.id }
        store.reorderTasks([ids[2], ids[1], ids[0]])
        store.save()
        let reloaded = JournalStore(directory: directory)
        XCTAssertEqual(numbers(reloaded), [3, 2, 1], "重新打开后顺序还在")

        reloaded.setDeadline(ids[2], to: tomorrow)
        XCTAssertNil(reloaded.locate(ids[2])?.task.listPosition, "改了截止日期，手动位置作废")
        XCTAssertEqual(numbers(reloaded), [3, 2, 1], "#3 有了截止日期，按截止时间排到最前；另外两个保持手动顺序")
        reloaded.setDeadline(ids[0], to: tomorrow)
        XCTAssertEqual(numbers(reloaded), [1, 3, 2], "#1 同一天截止、编号更小，排在 #3 前面——手动位置不再覆盖它")
    }

    func testReorderIsOneUndoableAction() throws {
        let (store, _) = makeStore()
        for title in ["甲", "乙"] { store.addTodo(title, on: day) }
        let ids = numbers(store).compactMap { store.locate(number: $0)?.id }
        store.reorderTasks([ids[1], ids[0]])
        XCTAssertEqual(numbers(store), [2, 1])
        XCTAssertEqual(store.lastAction?.name.contains("顺序"), true)
        store.undo()
        XCTAssertEqual(numbers(store), [1, 2])
    }

    func testOldDataWithoutPositionsStillSortsByDeadlineThenNumber() throws {
        let (store, _) = makeStore()
        store.addParsedTodo("明天 乙", on: day)
        store.addParsedTodo("今天 甲", on: day)
        store.addTodo("丙", on: day)
        XCTAssertEqual(store.sortedTasks().map { $0.task.title.contains("甲") ? "甲" : $0.task.title.contains("乙") ? "乙" : "丙" }, ["甲", "乙", "丙"])
    }

    func testCalendarCellsFollowTheListOrderForTheSameDay() throws {
        let (store, _) = makeStore()
        for title in ["甲", "乙", "丙"] { store.addParsedTodo("明天 \(title)", on: day, now: day) }
        let key = JournalDates.key(tomorrow)
        func cell() -> [Int] { (store.calendarDeadlines[key] ?? []).compactMap(\.task.number) }
        XCTAssertEqual(cell(), [1, 2, 3])
        let ids = numbers(store).compactMap { store.locate(number: $0)?.id }
        store.reorderTasks([ids[2], ids[0], ids[1]])
        XCTAssertEqual(numbers(store), [3, 1, 2])
        XCTAssertEqual(cell(), [3, 1, 2], "日历格子里的相对顺序和左边清单一致")
        store.undo()
        XCTAssertEqual(cell(), [1, 2, 3], "撤销后同步还原")
    }
}
