import XCTest
@testable import TimelineCore

@MainActor
final class LogImageTests: XCTestCase {
    private let day = JournalDates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7))!

    private func makeStore() -> (JournalStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (JournalStore(directory: directory), directory)
    }

    func testOldLogsDecodeWithoutImagesAndEncodeWithoutNewKeys() throws {
        let json = #"{"id":"4CC72FA1-6824-43AF-82D8-345E9C48588F","createdAt":0,"kind":"note","text":"旧日志"}"#
        let log = try JSONDecoder().decode(DailyLogEntry.self, from: Data(json.utf8))
        XCTAssertTrue(log.images.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(log), as: UTF8.self)
        XCTAssertFalse(encoded.contains("images"))
        XCTAssertFalse(encoded.contains("imageText"))
    }

    func testDraftImagesSurviveReloadAndAttachToCommittedLog() throws {
        let (store, directory) = makeStore()
        let name = try store.storeImage(Data([1, 2, 3]), fileExtension: "png")
        store.addDraftImage(name, on: day)
        store.setLogDraft("看到这个报错", on: day)
        store.save()
        let reloaded = JournalStore(directory: directory)
        XCTAssertEqual(reloaded.entry(for: day).logDraftImages, [name])
        try reloaded.commitLog(on: day)
        let entry = reloaded.entry(for: day)
        XCTAssertEqual(entry.logs.first?.images, [name])
        XCTAssertTrue(entry.logDraftImages.isEmpty)
        XCTAssertEqual(reloaded.imagesMissingText(), [name])
    }

    func testImageOnlyLogIsAllowedAndSurvivesEmptyEdit() throws {
        let (store, _) = makeStore()
        let name = try store.storeImage(Data([9]), fileExtension: "png")
        XCTAssertThrowsError(try store.commitLog(on: day))
        store.addDraftImage(name, on: day)
        try store.commitLog(on: day)
        let log = try XCTUnwrap(store.entry(for: day).logs.first)
        XCTAssertEqual(log.text, "")
        store.updateLog(log.id, text: "", on: day)
        XCTAssertEqual(store.entry(for: day).logs.count, 1, "带图片的记录清空文字后不应被删除")
        store.updateLog(log.id, text: "补充说明", on: day)
        XCTAssertEqual(store.entry(for: day).logs.first?.text, "补充说明")
    }

    func testRecognizedTextIsStoredPerImageAndSearchable() throws {
        let (store, _) = makeStore()
        let name = try store.storeImage(Data([7]), fileExtension: "png")
        _ = try store.quickLog("截图", images: [name], on: day)
        XCTAssertEqual(store.imagesMissingText(), [name])
        store.setImageText("Segmentation fault\n内存越界", image: name)
        XCTAssertTrue(store.imagesMissingText().isEmpty)
        let log = try XCTUnwrap(store.entry(for: day).logs.first)
        XCTAssertTrue(log.recognizedText.localizedStandardContains("越界"))
        store.setImageText("", image: name)
        XCTAssertTrue(store.imagesMissingText().isEmpty, "识别过但没有文字的图片不应反复识别")
    }

    func testExportFolderContainsJournalAndImagesAndCanBeImported() throws {
        let (store, _) = makeStore()
        let name = try store.storeImage(Data([4, 5, 6]), fileExtension: "png")
        let unused = try store.storeImage(Data([0]), fileExtension: "png")
        _ = try store.quickLog("带图", images: [name], on: day)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try store.exportFolder(to: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("journal.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Images/\(name)").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Images/\(unused)").path), "只导出被引用的图片")
        let (fresh, _) = makeStore()
        XCTAssertEqual(try fresh.importImages(from: folder), 1)
        XCTAssertEqual(try Data(contentsOf: fresh.imageURL(name)), Data([4, 5, 6]))
        XCTAssertEqual(try fresh.importImages(from: folder), 0, "已存在的图片不重复复制")
        XCTAssertEqual(try fresh.inspectBackup(folder.appendingPathComponent("journal.json")).logCount, 1)
    }

    func testCleanupKeepsReferencedAndBackedUpImagesAndHonoursGracePeriod() throws {
        let (store, _) = makeStore()
        let kept = try store.storeImage(Data([1]), fileExtension: "png")
        let backedUp = try store.storeImage(Data([2]), fileExtension: "png")
        let orphan = try store.storeImage(Data([3]), fileExtension: "png")
        _ = try store.quickLog("引用中", images: [kept], on: day)
        try FileManager.default.createDirectory(at: store.backupsDirectory, withIntermediateDirectories: true)
        try Data("{\"images\":[\"\(backedUp)\"]}".utf8).write(to: store.backupsDirectory.appendingPathComponent("2026-10-01.json"))
        XCTAssertEqual(Set(store.unusedImageNames()), [orphan])
        XCTAssertEqual(store.removeUnusedImages(olderThan: 3600), 0, "刚保存的图片留有宽限期，便于撤销")
        XCTAssertEqual(store.removeUnusedImages(olderThan: 0, now: Date().addingTimeInterval(1)), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(kept).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(backedUp).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL(orphan).path))
    }

    func testReviewMentionsImageOnlyLogs() throws {
        let (store, _) = makeStore()
        let name = try store.storeImage(Data([1]), fileExtension: "png")
        _ = try store.quickLog("", images: [name], on: day)
        XCTAssertTrue(DailyReview.render(store.entry(for: day)).contains("[图片 1 张]"))
    }
}
