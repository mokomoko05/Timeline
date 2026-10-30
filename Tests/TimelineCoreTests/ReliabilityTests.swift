import XCTest
@testable import TimelineCore

@MainActor
final class ReliabilityTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TimelineReliability-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRecoveryFailureRollsBackDeletionAndRetriesTogether() throws {
        let root = try directory(), store = JournalStore(directory: root)
        let date = Date()
        let id = try XCTUnwrap(try store.quickLogEntry("Keep me recoverable", on: date).entry?.id)
        let db = try JournalDatabase(url: store.databaseURL)
        try db.execute("CREATE TRIGGER recovery_failure BEFORE INSERT ON recovery WHEN NEW.key='trash' BEGIN SELECT RAISE(ABORT, 'recovery full'); END")
        store.deleteLog(id, on: date)
        XCTAssertNotNil(store.errorMessage)
        let disk = JournalStore(directory: root, readOnlySnapshot: true)
        XCTAssertTrue(disk.allLogs().contains { $0.id == id })
        XCTAssertTrue(disk.recentlyDeleted.isEmpty)
        try db.execute("DROP TRIGGER recovery_failure")
        store.save()
        let retried = JournalStore(directory: root, readOnlySnapshot: true)
        XCTAssertFalse(retried.allLogs().contains { $0.id == id })
        XCTAssertEqual(retried.recentlyDeleted.map(\.id), [id])
        XCTAssertNil(store.errorMessage)
    }

    func testLegacyHistoryAndTrashAreImportedWithoutOpeningHistory() async throws {
        let root = try directory(), date = Date(), id = UUID()
        let old = BoardVersion(savedAt: date, markdown: "A preserved historical page")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("BoardHistory"), withIntermediateDirectories: true)
        try JSONEncoder().encode([old]).write(to: root.appendingPathComponent("BoardHistory/" + id.uuidString + ".json"))
        let deleted = DailyLogEntry(createdAt: date, kind: .note, text: "Legacy trash")
        try JSONEncoder().encode([DeletedItem(id: deleted.id, deletedAt: date, content: .log(deleted, day: JournalDates.key(date)))]).write(to: root.appendingPathComponent("Trash.json"))
        let board = Board(id: id, owner: .tag("History"), title: "History")
        try JSONEncoder().encode(JournalDocument(boards: [board])).write(to: root.appendingPathComponent("journal.json"))
        let store = JournalStore(directory: root)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertEqual(store.recentlyDeleted.map(\.id), [deleted.id])
        let package = try await store.createBackupPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let data = try JSONDecoder().decode(JournalDocument.self, from: Data(contentsOf: package.appendingPathComponent("journal.json")))
        XCTAssertEqual(data.boardHistory?[id.uuidString], [old])
        XCTAssertEqual(JournalStore(directory: root, readOnlySnapshot: true).boardVersions(for: id), [old])
    }

    func testCorruptLegacyRecoveryIsVisibleAndProtected() throws {
        let root = try directory()
        try JSONEncoder().encode(JournalDocument()).write(to: root.appendingPathComponent("journal.json"))
        try Data("broken trash".utf8).write(to: root.appendingPathComponent("Trash.json"))
        let store = JournalStore(directory: root)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.databaseURL.path))
    }

    func testBackupRoundTripPreservesOriginalsDraftsAndRecovery() async throws {
        let store = JournalStore(directory: try directory()), date = Date()
        let original = Data((0..<200_000).map { UInt8($0 % 251) })
        let image = try store.storeImage(original, fileExtension: "png")
        let log = try XCTUnwrap(try store.quickLogEntry("Original image", images: [image], on: date).entry)
        store.setLogDraft("Draft text", on: date)
        let backup = try await store.createBackupPackage()
        defer { try? FileManager.default.removeItem(at: backup) }
        let preview = try await JournalStore.inspectBackupPackage(backup)
        XCTAssertEqual(preview.logs, 1); XCTAssertEqual(preview.images, 1)
        let destination = JournalStore(directory: try directory())
        _ = try destination.quickLog("Before restore", on: date)
        try await destination.restoreBackupPackage(backup)
        XCTAssertEqual(destination.entry(for: date).logDraft, "Draft text")
        XCTAssertTrue(destination.allLogs().contains { $0.id == log.id })
        XCTAssertTrue(destination.recentlyDeleted.contains { $0.title == "Before restore" })
        XCTAssertEqual(try Data(contentsOf: destination.imagesDirectory.appendingPathComponent(image)), original)
        let disk = JournalStore(directory: destination.directory, readOnlySnapshot: true)
        XCTAssertEqual(disk.days, destination.days)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.backupsDirectory.path).contains { $0.hasPrefix("before-restore-") })
        destination.undo()
        XCTAssertTrue(destination.allLogs().contains { $0.log.text == "Before restore" })
    }

    func testCorruptBackupCannotMutateLiveContentOrImages() async throws {
        let source = JournalStore(directory: try directory()), date = Date()
        let image = try source.storeImage(Data([1, 2, 3]), fileExtension: "png")
        _ = try source.quickLog("Photo", images: [image], on: date)
        let package = try await source.createBackupPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        try Data([9, 9, 9]).write(to: package.appendingPathComponent("Images/" + image))
        let target = JournalStore(directory: try directory())
        _ = try target.quickLog("Untouched", on: date)
        let before = target.documentSnapshot
        do { try await target.restoreBackupPackage(package); XCTFail("A corrupt original must stop restore") } catch { }
        XCTAssertEqual(target.documentSnapshot, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.imagesDirectory.appendingPathComponent(image).path))
    }

    func testBackupCanRecoverCorruptDatabaseWithoutDiscardingIt() async throws {
        let source = JournalStore(directory: try directory())
        _ = try source.quickLog("From backup", on: Date())
        let package = try await source.createBackupPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let root = try directory(), broken = Data("broken database".utf8)
        try broken.write(to: root.appendingPathComponent("journal.sqlite"))
        let target = JournalStore(directory: root)
        XCTAssertTrue(target.isReadOnly)
        try await target.restoreBackupPackage(package)
        XCTAssertFalse(target.isReadOnly)
        XCTAssertEqual(JournalStore(directory: root, readOnlySnapshot: true).allLogs().first?.log.text, "From backup")
        let archive = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: target.backupsDirectory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("before-restore-database-") })
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("journal.sqlite")), broken)
    }

    func testSearchUpdatesEditsDeletesArchivesAndMatchesPinyin() async throws {
        let store = JournalStore(directory: try directory()), date = Date()
        store.addTodo("整理资料", on: date)
        let log = try XCTUnwrap(try store.quickLogEntry("needle in log", on: date).entry)
        let board = try XCTUnwrap(store.ensureBoard(for: .tag("Search")))
        store.setBoardMarkdown("needle in board", for: board.id)
        let index = JournalSearchIndex()
        func snapshot() -> JournalSearchSnapshot { JournalSearchSnapshot(days: store.days, boards: store.boards) }
        let initial = try await index.search(snapshot(), query: "needle")
        XCTAssertTrue(initial.logs.contains(log.id)); XCTAssertEqual(initial.boardLines[board.id], [0])
        let pinyin = try await index.search(snapshot(), query: "zhengli")
        XCTAssertEqual(pinyin.tasks.first?.task.title, "整理资料")
        store.updateLog(log.id, text: "Changed", on: date)
        var archived = store.syncContent; archived.boards[0].archived = true; store.applySyncContent(archived)
        let updated = try await index.search(snapshot(), query: "needle")
        XCTAssertTrue(updated.logs.isEmpty); XCTAssertNil(updated.boardLines[board.id])
        store.deleteLog(log.id, on: date)
        let removed = try await index.search(snapshot(), query: "Changed")
        XCTAssertTrue(removed.locatedLogs.isEmpty)
    }

    func testReminderSnoozeLifecycleIncludesAlreadyFiredTasks() {
        let id = UUID(), name = "timeline-snooze." + id.uuidString
        var task = Todo(id: id, title: "Expired reminder")
        task.dueDate = Date().addingTimeInterval(-3600); task.reminderMinutes = 0
        var day = DayEntry(); day.todos = [task]
        let before = ReminderLifecycleSnapshot(days: ["2026-10-30": day])
        day.todos[0].completed = true
        let after = ReminderLifecycleSnapshot(days: ["2026-10-30": day])
        XCTAssertTrue(before.plans.isEmpty); XCTAssertTrue(after.plans.isEmpty)
        XCTAssertNotEqual(before, after)
        XCTAssertFalse(ReminderLifecycle.shouldRemove(name, taskID: id, desired: [], activeTasks: before.activeTasks, enabled: true))
        XCTAssertTrue(ReminderLifecycle.shouldRemove(name, taskID: id, desired: [], activeTasks: after.activeTasks, enabled: true))
        XCTAssertTrue(ReminderLifecycle.shouldRemove(name, taskID: id, desired: [], activeTasks: [id], enabled: false))
        XCTAssertFalse(ReminderLifecycle.shouldRemove("focus.timer", taskID: nil, desired: [], activeTasks: [], enabled: false))
    }

    func testOutboxIsIndependentAndSurvivesTransportUpdatesAndRollback() throws {
        let db = try JournalDatabase(url: try directory().appendingPathComponent("journal.sqlite"))
        var state = SyncState(device: "test", commitID: "commit", records: [:], ledger: IncrementalState())
        try IncrementalSync.prepare(state: &state.ledger!, previous: [:], records: [:], device: "test", name: "Test", now: Date())
        let document = JournalDocument(syncCommitID: "commit")
        try db.save(document, state: state)
        XCTAssertEqual(try db.scalar("SELECT count(*) FROM outbox"), 1)
        XCTAssertEqual(try db.scalar("SELECT json_array_length(CAST(value AS TEXT), '$.pending') FROM metadata WHERE key='transport'"), 0)
        state.ledger?.pendingCloud.insert("file.json")
        try db.saveTransport(state)
        XCTAssertEqual(try db.loadSyncState(), state)
        try db.execute("CREATE TRIGGER transport_failure BEFORE INSERT ON metadata WHEN NEW.key='transport' BEGIN SELECT RAISE(ABORT, 'transport full'); END")
        var drained = state; drained.ledger?.pending = []
        XCTAssertThrowsError(try db.saveTransport(drained))
        XCTAssertEqual(try db.loadSyncState(), state, "Outbox removal rolls back with failed transport update")
        try db.execute("DROP TRIGGER transport_failure")
        try db.saveTransport(drained)
        XCTAssertEqual(try db.scalar("SELECT count(*) FROM outbox"), 0)
    }

    func testDateScopedPersistenceAndIndexedRangeKeepMovesCorrect() async throws {
        let db = try JournalDatabase(url: try directory().appendingPathComponent("journal.sqlite"))
        var document = JournalDocument()
        for index in 0..<1000 {
            let date = JournalDates.calendar.date(byAdding: .day, value: -index, to: Date())!
            var day = DayEntry(); day.logs = [DailyLogEntry(createdAt: date, kind: .note, text: "Record \(index)")]
            document.days[JournalDates.key(date)] = day
        }
        try db.save(document)
        let keys = document.days.keys.sorted(), from = keys[200], to = keys[201]
        let moving = document.days[from]!.logs.removeFirst()
        document.days[to]!.logs.append(moving)
        try db.save(document, changedDays: [from, to])
        XCTAssertEqual(db.lastComparedDays, 2)
        let range = try db.loadDays(from: from, through: to)
        XCTAssertEqual(range, document.days.filter { $0.key >= from && $0.key <= to })
        XCTAssertEqual(try db.load(), document)
    }
    func testCorruptPeerDoesNotBlockOtherPeerOrLocalPublicationAndRecovers() async throws {
        let cloud = try directory()
        let a = FolderSync(store: JournalStore(directory: try directory()), folder: cloud, deviceName: "A")
        let b = FolderSync(store: JournalStore(directory: try directory()), folder: cloud, deviceName: "B")
        let c = FolderSync(store: JournalStore(directory: try directory()), folder: cloud, deviceName: "C")
        let boardA = try XCTUnwrap(a.store.ensureBoard(for: .tag("Broken")))
        a.store.setBoardMarkdown("Safe", for: boardA.id)
        try await a.sync(); try await b.sync(); try await c.sync()
        let cursor = try b.store.persistedSyncState()?.ledger?.received[a.deviceID]
        a.store.setBoardMarkdown("Newer", for: boardA.id); try await a.sync()
        let stream = cloud.appendingPathComponent("streams/" + a.deviceID)
        let corrupt = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: stream, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }.last)
        let valid = try Data(contentsOf: corrupt)
        try Data("bad batch".utf8).write(to: corrupt)
        let boardC = try XCTUnwrap(c.store.ensureBoard(for: .tag("Healthy")))
        c.store.setBoardMarkdown("From healthy C", for: boardC.id)
        try await c.sync()
        _ = try b.store.quickLog("B can still publish", on: Date())
        try await b.sync()
        XCTAssertEqual(b.store.board(id: boardA.id)?.markdown, "Safe")
        XCTAssertEqual(b.store.board(id: boardC.id)?.markdown, "From healthy C")
        XCTAssertEqual(try b.store.persistedSyncState()?.ledger?.received[a.deviceID], cursor)
        XCTAssertTrue(b.fileErrors.keys.contains { $0.hasSuffix(corrupt.lastPathComponent) })
        try await c.sync()
        XCTAssertTrue(c.store.allLogs().contains { $0.log.text == "B can still publish" })
        try valid.write(to: corrupt)
        try await b.sync()
        XCTAssertEqual(b.store.board(id: boardA.id)?.markdown, "Newer")
        XCTAssertTrue(b.fileErrors.isEmpty)
    }

    func testAttachmentFailurePublishesTextAndKeepsDurableRetryQueue() async throws {
        let cloud = try directory(), root = try directory(), date = Date()
        let store = JournalStore(directory: root)
        let image = try store.storeImage(Data([1, 2, 3, 4]), fileExtension: "png")
        _ = try store.quickLog("Text survives image failure", images: [image], on: date)
        try Data("blocks image directory".utf8).write(to: cloud.appendingPathComponent("images"))
        let sync = FolderSync(store: store, folder: cloud, deviceName: "Sender")
        try await sync.sync()
        XCTAssertFalse(sync.fileErrors.isEmpty)
        XCTAssertTrue(try store.persistedSyncState()?.ledger?.queuedImages?.contains(image) == true)
        let receiver = FolderSync(store: JournalStore(directory: try directory()), folder: cloud, deviceName: "Receiver")
        try await receiver.sync()
        XCTAssertTrue(receiver.store.allLogs().contains { $0.log.text == "Text survives image failure" })
        try FileManager.default.removeItem(at: cloud.appendingPathComponent("images"))
        let restarted = FolderSync(store: JournalStore(directory: root), folder: cloud, deviceName: "Sender")
        try await restarted.sync()
        XCTAssertTrue(restarted.fileErrors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: cloud.appendingPathComponent("images/" + image)), Data([1, 2, 3, 4]))
    }

    func testRetiredDeviceRejoinsWithNewIdentityWithoutResurrectingDeletedTask() async throws {
        let cloud = try directory(), root = try directory(), date = Date()
        let a = FolderSync(store: JournalStore(directory: try directory()), folder: cloud, deviceName: "A")
        let b = FolderSync(store: JournalStore(directory: root), folder: cloud, deviceName: "B")
        a.store.addTodo("Delete this", on: date)
        try await a.sync(); try await b.sync(); try await a.sync()
        let originalID = b.deviceID
        let task = try XCTUnwrap(a.store.tasks().first)
        a.store.deleteTodo(task.id, on: date)
        try await a.sync()
        _ = try b.store.quickLog("Offline old device edit", on: date)
        try await a.retireDevice(originalID)
        // Let the queued publication finish before restarting the retired peer.
        for _ in 0..<30 { try await Task.sleep(nanoseconds: 10_000_000); if !a.isSyncing { break } }
        try await a.sync()
        let rejoined = FolderSync(store: JournalStore(directory: root), folder: cloud, deviceName: "B")
        try await rejoined.sync()
        XCTAssertNotEqual(rejoined.deviceID, originalID)
        XCTAssertNil(rejoined.store.locate(task.id))
        XCTAssertTrue(rejoined.store.allLogs().contains { $0.log.text == "Offline old device edit" })
        try await a.sync()
        XCTAssertTrue(a.store.allLogs().contains { $0.log.text == "Offline old device edit" })
        XCTAssertTrue(a.devices.contains { $0.id == originalID && $0.isRetired })
    }

    func testOlderSaveCannotClearANewerDebouncedEdit() async throws {
        let store = JournalStore(directory: try directory()), date = Date()
        store.writesInBackground = true
        _ = try store.quickLog("First write", on: date)
        store.setLogDraft("Newer draft waiting for debounce", on: date)
        // The older completion runs before the debounced write starts.
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(store.hasPendingSave)
        try await store.saveAndWait()
        XCTAssertEqual(JournalStore(directory: store.directory, readOnlySnapshot: true).entry(for: date).logDraft, "Newer draft waiting for debounce")
    }

    func testSearchTagUsesCurrentTaskTagsAndCanceledSearchDoesNotPublish() async throws {
        let store = JournalStore(directory: try directory()), date = Date()
        store.addTodo("Linked task", on: date)
        let task = try XCTUnwrap(store.tasks().first)
        store.setTags(task.id, ["Old"])
        let log = try XCTUnwrap(try store.quickLogEntry("Linked log", taskID: task.id, on: date).entry)
        let index = JournalSearchIndex()
        store.setTags(task.id, ["New"])
        let snapshot = JournalSearchSnapshot(days: store.days, boards: store.boards)
        let old = try await index.search(snapshot, query: "#Old")
        let new = try await index.search(snapshot, query: "#New")
        XCTAssertFalse(old.logs.contains(log.id))
        XCTAssertTrue(new.logs.contains(log.id))
        let canceled = Task { try await index.search(snapshot, query: "Linked") }
        canceled.cancel()
        do { _ = try await canceled.value; XCTFail("Cancelled search should not produce results") } catch is CancellationError { }
        let final = try await index.search(snapshot, query: "Linked")
        XCTAssertTrue(final.logs.contains(log.id))
    }

    func testBackupRestoresPinnedTaskAndKeepsTaskNumbersUnique() async throws {
        let source = JournalStore(directory: try directory()), date = Date()
        source.addTodo("Pinned from backup", on: date)
        let originalTask = try XCTUnwrap(source.tasks().first)
        XCTAssertTrue(source.pinTask(originalTask.id))
        let package = try await source.createBackupPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let target = JournalStore(directory: try directory())
        try await target.restoreBackupPackage(package)
        XCTAssertEqual(target.pinnedTask?.id, originalTask.id)
        target.addTodo("New task after restore", on: date)
        let numbers = target.tasks().compactMap { $0.task.number }
        XCTAssertEqual(numbers.count, Set(numbers).count)
    }

    func testBackupRejectsEscapingImageSymlinkAndPathTraversal() async throws {
        let source = JournalStore(directory: try directory()), date = Date()
        let image = try source.storeImage(Data([1, 2, 3]), fileExtension: "png")
        _ = try source.quickLog("Image", images: [image], on: date)
        let package = try await source.createBackupPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let outside = try directory().appendingPathComponent("outside.png")
        try Data([1, 2, 3]).write(to: outside)
        let url = package.appendingPathComponent("Images/" + image)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        do { _ = try await JournalStore.inspectBackupPackage(package); XCTFail("Escaping symlink must be rejected") } catch { }
        let manifestURL = package.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var files = try XCTUnwrap(manifest["files"] as? [String: String])
        files["Images/../../outside.png"] = IncrementalSync.digest(Data([1, 2, 3]))
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        do { _ = try await JournalStore.inspectBackupPackage(package); XCTFail("Path traversal must be rejected") } catch { }
    }

    func testLeaseFailureDoesNotBlockPublicationAndRetriesImmediately() async throws {
        let cloud = try directory(), store = JournalStore(directory: try directory())
        try Data("blocks leases".utf8).write(to: cloud.appendingPathComponent("image-leases"))
        _ = try store.quickLog("Must publish without lease", on: Date())
        let sync = FolderSync(store: store, folder: cloud, deviceName: "Sender")
        try await sync.sync()
        XCTAssertTrue(sync.fileErrors.keys.contains { $0.hasPrefix("image-leases/") })
        let peer = FolderSync(store: JournalStore(directory: try directory()), folder: cloud, deviceName: "Peer")
        try await peer.sync()
        XCTAssertTrue(peer.store.allLogs().contains { $0.log.text == "Must publish without lease" })
        try FileManager.default.removeItem(at: cloud.appendingPathComponent("image-leases"))
        try await sync.sync()
        XCTAssertTrue(sync.fileErrors.isEmpty)
        XCTAssertNotNil(try store.persistedSyncState()?.ledger?.imageLease)
    }

    func testDeferredRemoteDeletionDoesNotStartOrdinaryAutosave() async throws {
        let store = JournalStore(directory: try directory()), date = Date()
        let log = try XCTUnwrap(try store.quickLogEntry("Keep until atomic commit", on: date).entry)
        store.setLogDraft("Previously queued debounce", on: date)
        var remote = store.syncContent
        remote.days[JournalDates.key(date)]?.logs = []
        store.applySyncContent(remote, persistImmediately: false)
        try await Task.sleep(nanoseconds: 350_000_000)
        store.waitForPendingWrites()
        let disk = JournalStore(directory: store.directory, readOnlySnapshot: true)
        XCTAssertTrue(disk.allLogs().contains { $0.id == log.id })
        XCTAssertTrue(disk.recentlyDeleted.isEmpty)
        XCTAssertTrue(store.recentlyDeleted.contains { $0.id == log.id })
    }

    func testFailedSyncCommitRetriesBaselineWithEverySavePath() async throws {
        for path in ["save", "await", "background", "retry"] {
            let store = JournalStore(directory: try directory()), date = Date()
            store.saveRetryDelays = [0.05]
            let log = try XCTUnwrap(try store.quickLogEntry("Remote deletion", on: date).entry)
            let before = store.documentSnapshot
            var remote = store.syncContent
            remote.days[JournalDates.key(date)]?.logs = []
            var records: [String: SyncRecord] = [:]
            var merge = SyncMerge(device: "atomic", now: date)
            merge.stampLocalChanges(try store.syncContent.records(), into: &records)
            merge.stampLocalChanges(try remote.records(), into: &records)
            let next = SyncState(device: "atomic", commitID: UUID().uuidString, records: records, ledger: IncrementalState())
            let db = try JournalDatabase(url: store.databaseURL)
            try db.execute("CREATE TRIGGER fail_sync BEFORE INSERT ON metadata WHEN NEW.key='sync' BEGIN SELECT RAISE(ABORT, 'sync blocked'); END")
            store.applySyncContent(remote, persistImmediately: false)
            do { try await store.saveForSync(state: next); XCTFail("Must reject failed sync transaction") } catch { }
            XCTAssertEqual(JournalStore(directory: store.directory, readOnlySnapshot: true).documentSnapshot, before)
            try db.execute("DROP TRIGGER fail_sync")
            // A new edit must be saved alongside, while keeping the remote baseline intact.
            store.setLogDraft("Edit after failed commit", on: date)
            switch path {
            case "save": store.save()
            case "await": try await store.saveAndWait()
            case "background": store.saveInBackground(); try await Task.sleep(nanoseconds: 50_000_000)
            default: try await Task.sleep(nanoseconds: 150_000_000)
            }
            store.waitForPendingWrites()
            let disk = JournalStore(directory: store.directory, readOnlySnapshot: true)
            XCTAssertTrue(disk.allLogs().isEmpty, path)
            XCTAssertEqual(disk.recentlyDeleted.map(\.id), [log.id], path)
            XCTAssertEqual(disk.entry(for: date).logDraft, "Edit after failed commit", path)
            XCTAssertEqual(disk.documentSnapshot.syncCommitID, next.commitID, path)
            XCTAssertEqual(try disk.persistedSyncState(), next, path)
            XCTAssertNil(store.errorMessage, path)
        }
    }

    func testRestoreRejectsEditsDuringInitialPackagePreparation() async throws {
        let source = JournalStore(directory: try directory()), target = JournalStore(directory: try directory()), date = Date()
        let image = try source.storeImage(Data(repeating: 42, count: 20_000_000), fileExtension: "png")
        _ = try source.quickLog("Backup", images: [image], on: date)
        let package = try await source.createBackupPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let started = expectation(description: "Restore entered")
        let restoring = Task { @MainActor in
            started.fulfill()
            try await target.restoreBackupPackage(package)
        }
        await fulfillment(of: [started], timeout: 2)
        _ = try target.quickLog("Edit during preparation", on: date)
        do { try await restoring.value; XCTFail("Preparation-time edits must cancel restore") }
        catch BackupRestoreError.changedWhilePreparing { }
        XCTAssertEqual(target.allLogs().map { $0.log.text }, ["Edit during preparation"])
        XCTAssertTrue(target.recentlyDeleted.isEmpty)
        XCTAssertEqual(JournalStore(directory: target.directory, readOnlySnapshot: true).days, target.days)
    }

    func testRestoreUndoRedoPreservesPinnedTaskAndFavoriteOrder() async throws {
        let source = JournalStore(directory: try directory()), target = JournalStore(directory: try directory()), date = Date()
        source.addTodo("Backup pinned", on: date)
        let backupTask = try XCTUnwrap(source.tasks().first)
        source.pinTask(backupTask.id)
        let backupBoard = try XCTUnwrap(source.ensureBoard(for: .tag("Backup")))
        source.setBoardFavoriteOrder([backupBoard.id])
        target.addTodo("Original pinned", on: date)
        let original = try XCTUnwrap(target.tasks().first)
        target.pinTask(original.id)
        let originalBoard = try XCTUnwrap(target.ensureBoard(for: .tag("Original")))
        target.setBoardFavoriteOrder([originalBoard.id])
        let package = try await source.createBackupPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        try await target.restoreBackupPackage(package)
        for _ in 0..<2 {
            XCTAssertEqual(target.pinnedTask?.id, backupTask.id)
            XCTAssertEqual(target.favoriteBoardIDs, [backupBoard.id])
            target.undo()
            XCTAssertEqual(target.pinnedTask?.id, original.id)
            XCTAssertEqual(target.favoriteBoardIDs, [originalBoard.id])
            target.redo()
        }
        try await target.saveAndWait()
        let disk = JournalStore(directory: target.directory, readOnlySnapshot: true)
        XCTAssertEqual(disk.pinnedTask?.id, backupTask.id)
        XCTAssertEqual(disk.favoriteBoardIDs, [backupBoard.id])
    }

    func testRetirementWriteFailureSurvivesRestartAndRetriesWithoutRewriting() async throws {
        let cloud = try directory(), local = try directory(), date = Date()
        let a = FolderSync(store: JournalStore(directory: local), folder: cloud, deviceName: "A")
        let b = FolderSync(store: JournalStore(directory: try directory()), folder: cloud, deviceName: "B")
        _ = try a.store.quickLog("Published data", on: date)
        try await a.sync(); try await b.sync(); try await a.sync()
        let path = cloud.appendingPathComponent("retired-devices")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path) }
        do { try await a.retireDevice(b.deviceID); XCTFail("Retirement write must fail") } catch { }
        a.stopAutomaticSync()
        XCTAssertNotNil(try a.store.persistedSyncState()?.ledger?.pendingRetirements?[b.deviceID])
        XCTAssertNotNil(a.fileErrors["retired-devices/" + b.deviceID + ".json"])
        // Drain the already scheduled follow-up while failure is still injected.
        try await Task.sleep(nanoseconds: 50_000_000)
        a.stopAutomaticSync()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        let restarted = FolderSync(store: JournalStore(directory: local), folder: cloud, deviceName: "A")
        try await restarted.sync()
        let marker = path.appendingPathComponent(b.deviceID + ".json")
        let data = try Data(contentsOf: marker), modified = try marker.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertTrue(try restarted.store.persistedSyncState()?.ledger?.pendingRetirements?.isEmpty == true)
        XCTAssertTrue(restarted.fileErrors.isEmpty)
        try await restarted.sync()
        XCTAssertTrue(restarted.devices.contains { $0.id == b.deviceID && $0.isRetired })
        XCTAssertEqual(try Data(contentsOf: marker), data)
        XCTAssertEqual(try marker.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
    }

    func testLateFailedSaveCallbackCannotOverwriteNewerSuccess() async throws {
        let store = JournalStore(directory: try directory()), date = Date()
        _ = try store.quickLog("Initial", on: date)
        let db = try JournalDatabase(url: store.databaseURL)
        try db.execute("CREATE TRIGGER block_write BEFORE INSERT ON entities BEGIN SELECT RAISE(ABORT, 'blocked'); END")
        store.writesInBackground = true
        _ = try store.quickLog("Retry me", on: date)
        // Keep the main actor occupied so the old failure callback remains queued.
        store.waitForPendingWrites()
        try db.execute("DROP TRIGGER block_write")
        store.save()
        XCTAssertNil(store.errorMessage)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.hasPendingSave)
        XCTAssertEqual(JournalStore(directory: store.directory, readOnlySnapshot: true).allLogs().count, 2)
    }

    func testSyncAfterFailedCommitKeepsRemoteDeletionAndNewLocalEdit() async throws {
        let cloud = try directory(), date = Date()
        let a = FolderSync(store: JournalStore(directory: try directory()), folder: cloud, deviceName: "A")
        let b = FolderSync(store: JournalStore(directory: try directory()), folder: cloud, deviceName: "B")
        let log = try XCTUnwrap(try a.store.quickLogEntry("Delete remotely", on: date).entry)
        try await a.sync(); try await b.sync(); try await a.sync()
        let db = try JournalDatabase(url: b.store.databaseURL)
        try db.execute("CREATE TRIGGER block_sync BEFORE INSERT ON metadata WHEN NEW.key='sync' BEGIN SELECT RAISE(ABORT, 'blocked'); END")
        a.store.deleteLog(log.id, on: date)
        try await a.sync()
        do { try await b.sync(); XCTFail("Must fail atomic commit") } catch { }
        XCTAssertTrue(JournalStore(directory: b.store.directory, readOnlySnapshot: true).allLogs().contains { $0.id == log.id })
        try db.execute("DROP TRIGGER block_sync")
        _ = try b.store.quickLog("New local edit", on: date)
        try await b.sync(); try await a.sync()
        for store in [a.store, b.store, JournalStore(directory: b.store.directory, readOnlySnapshot: true)] {
            XCTAssertFalse(store.allLogs().contains { $0.id == log.id })
            XCTAssertTrue(store.allLogs().contains { $0.log.text == "New local edit" })
        }
        XCTAssertNil(b.store.errorMessage)
    }

    func testLateSuccessfulSaveCannotCancelNewerFailureRetry() async throws {
        let store = JournalStore(directory: try directory()), date = Date()
        store.saveRetryDelays = [0.05]
        _ = try store.quickLog("Initial", on: date)
        store.saveInBackground()
        store.waitForPendingWrites()
        let db = try JournalDatabase(url: store.databaseURL)
        try db.execute("CREATE TRIGGER fail_newer BEFORE INSERT ON entities BEGIN SELECT RAISE(ABORT, 'newer blocked'); END")
        _ = try store.quickLog("Newer failed save", on: date)
        XCTAssertNotNil(store.errorMessage)
        try db.execute("DROP TRIGGER fail_newer")
        // The old successful background completion now runs before the retry timer.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.hasPendingSave)
        XCTAssertEqual(JournalStore(directory: store.directory, readOnlySnapshot: true).allLogs().count, 2)
    }

}
