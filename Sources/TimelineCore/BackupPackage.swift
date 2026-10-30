import Foundation

public struct BackupPackagePreview: Sendable {
    public let tasks: Int
    public let logs: Int
    public let boards: Int
    public let images: Int
    public let bytes: Int
    /// 导出时就缺的原图张数（用户确认过），恢复后这些图片仍然打不开。
    public let missingImages: Int
}

public enum BackupPackageError: LocalizedError {
    /// 这些原图找不到：可以补齐后重试，或确认后不带它们导出。
    case missingImages([String])
    public var errorDescription: String? { ImageExportError.unavailable.errorDescription }
}

private struct BackupManifest: Codable {
    var format = 1
    var createdAt: Date
    var files: [String: String]
    /// 导出时用户确认可以缺的原图；没列在这里又不在 `files` 里的算备份损坏。
    var missingImages: [String]? = nil
}

private enum BackupFiles {
    static func imageNames(_ document: JournalDocument) -> Set<String> {
        var names = Set(document.days.values.flatMap { $0.logs.flatMap(\.images) + $0.logDraftImages })
        for item in document.recentlyDeleted ?? [] { if case .log(let log, _) = item.content { names.formUnion(log.images) } }
        return names
    }
    static func safe(_ name: String) -> Bool { !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") }

    static func validate(_ folder: URL) throws -> (JournalDocument, BackupPackagePreview) {
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        guard manifest.format == 1, manifest.files["journal.json"] != nil else { throw CocoaError(.fileReadCorruptFile) }
        var bytes = 0
        var journalData: Data?
        for (relative, hash) in manifest.files {
            guard relative == "journal.json" || (relative.hasPrefix("Images/") && safe(String(relative.dropFirst(7)))) else { throw CocoaError(.fileReadInvalidFileName) }
            let url = folder.appendingPathComponent(relative)
            guard url.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
            try Task.checkCancellation()
            let data = try Data(contentsOf: url)
            guard IncrementalSync.digest(data) == hash else { throw CocoaError(.fileReadCorruptFile) }
            bytes += data.count
            if relative == "journal.json" { journalData = data }
        }
        guard let journalData else { throw CocoaError(.fileReadCorruptFile) }
        let document = try JSONDecoder().decode(JournalDocument.self, from: journalData)
        guard (1...8).contains(document.version), document.days.keys.allSatisfy({ JournalDates.date(for: $0) != nil }) else { throw CocoaError(.fileReadCorruptFile) }
        let tasks = document.days.values.flatMap(\.todos), logs = document.days.values.flatMap(\.logs)
        guard Set(tasks.map(\.id)).count == tasks.count, Set(logs.map(\.id)).count == logs.count,
              Set((document.boards ?? []).map(\.id)).count == (document.boards?.count ?? 0) else { throw CocoaError(.fileReadCorruptFile) }
        let historyIDs = (document.boardHistory ?? [:]).keys.compactMap(UUID.init(uuidString:))
        guard historyIDs.count == (document.boardHistory?.count ?? 0), Set(historyIDs).count == historyIDs.count else { throw CocoaError(.fileReadCorruptFile) }
        for item in document.recentlyDeleted ?? [] {
            switch item.content {
            case .log(let log, let day): guard item.id == log.id, JournalDates.date(for: day) != nil else { throw CocoaError(.fileReadCorruptFile) }
            case .task(let task, let day): guard item.id == task.id, JournalDates.date(for: day) != nil else { throw CocoaError(.fileReadCorruptFile) }
            case .board(let board): guard item.id == board.id else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        let names = imageNames(document)
        let declared = Set(manifest.missingImages ?? [])
        guard declared.allSatisfy(safe), names.allSatisfy({ safe($0) && (manifest.files["Images/" + $0] != nil || declared.contains($0)) }) else { throw ImageExportError.unavailable }
        let missing = names.intersection(declared).filter { manifest.files["Images/" + $0] == nil }.count
        return (document, BackupPackagePreview(tasks: tasks.count, logs: logs.count, boards: document.boards?.count ?? 0, images: names.count - missing, bytes: bytes, missingImages: missing))
    }
    static func stage(_ folder: URL) throws -> (URL, JournalDocument) {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("Timeline-Restore-" + UUID().uuidString)
        do {
            _ = try validate(folder)
            let manifestData = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
            let manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData)
            try FileManager.default.createDirectory(at: target.appendingPathComponent("Images"), withIntermediateDirectories: true)
            for (relative, hash) in manifest.files {
                try Task.checkCancellation()
                guard relative == "journal.json" || (relative.hasPrefix("Images/") && safe(String(relative.dropFirst(7)))) else { throw CocoaError(.fileReadInvalidFileName) }
                let data = try Data(contentsOf: folder.appendingPathComponent(relative))
                guard IncrementalSync.digest(data) == hash else { throw CocoaError(.fileReadCorruptFile) }
                try data.write(to: target.appendingPathComponent(relative), options: .atomic)
            }
            try manifestData.write(to: target.appendingPathComponent("manifest.json"), options: .atomic)
            return (target, try validate(target).0)
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }

}

extension JournalStore {
    /// 导出固定快照及其原图；下载、编码、复制和摘要计算均不占用主线程。
    /// 找不到的原图默认中止（`BackupPackageError.missingImages` 列出它们）；用户确认后可以不带它们导出，其余内容照常备份。
    public func createBackupPackage(allowingMissingImages: Bool = false) async throws -> URL {
        let document = documentSnapshot
        var names = BackupFiles.imageNames(document)
        var missing: [String] = []
        for name in names.sorted() {
            guard BackupFiles.safe(name) else { throw CocoaError(.fileReadInvalidFileName) }
            if !FileManager.default.fileExists(atPath: imagesDirectory.appendingPathComponent(name).path) {
                if (try? await fetchImage?(name)) != true { missing.append(name) }
            }
        }
        if !missing.isEmpty, !allowingMissingImages { throw BackupPackageError.missingImages(missing) }
        names.subtract(missing)
        let images = imagesDirectory, declaredMissing = missing
        return try await Task.detached(priority: .utility) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Timeline-" + UUID().uuidString + ".timelinebackup")
            do {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("Images"), withIntermediateDirectories: true)
                var files: [String: String] = [:]
                let data = try JournalWriter.encode(document)
                try data.write(to: folder.appendingPathComponent("journal.json"), options: .atomic)
                files["journal.json"] = IncrementalSync.digest(data)
                for name in names {
                    try Task.checkCancellation()
                    let data = try Data(contentsOf: images.appendingPathComponent(name))
                    try data.write(to: folder.appendingPathComponent("Images").appendingPathComponent(name), options: .atomic)
                    files["Images/" + name] = IncrementalSync.digest(data)
                }
                try IncrementalSync.encode(BackupManifest(createdAt: Date(), files: files, missingImages: declaredMissing.isEmpty ? nil : declaredMissing)).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
                _ = try BackupFiles.validate(folder)
                return folder
            } catch { try? FileManager.default.removeItem(at: folder); throw error }
        }.value
    }

    public nonisolated static func inspectBackupPackage(_ folder: URL) async throws -> BackupPackagePreview {
        try await Task.detached(priority: .utility) { try BackupFiles.validate(folder).1 }.value
    }

    public func restoreBackupPackage(_ folder: URL) async throws {
        let initial = documentSnapshot
        // 任何摘要、缺图、格式校验失败都发生在修改正式内容之前。
        let (staging, validated) = try await Task.detached(priority: .utility) { try BackupFiles.stage(folder) }.value
        defer { Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: staging) } }
        let images = imagesDirectory
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            for name in BackupFiles.imageNames(validated) {
                // 校验已确认：不在备份里的都是导出时声明过缺失的。
                let source = staging.appendingPathComponent("Images").appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let data = try Data(contentsOf: source)
                let target = images.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) {
                    guard IncrementalSync.digest(try Data(contentsOf: target)) == IncrementalSync.digest(data) else { throw CocoaError(.fileReadCorruptFile) }
                } else { try data.write(to: target, options: .atomic) }
            }
        }.value
        guard documentSnapshot == initial else { throw BackupRestoreError.changedWhilePreparing }
        if !isReadOnly {
            try await saveAndWait()
            guard documentSnapshot == initial else { throw BackupRestoreError.changedWhilePreparing }
            let current = initial, backups = backupsDirectory
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                try JournalWriter.encode(current).write(to: backups.appendingPathComponent("before-restore-" + UUID().uuidString + ".json"), options: .atomic)
            }.value
            guard documentSnapshot == current else { throw BackupRestoreError.changedWhilePreparing }
        } else { try await archiveForPackageRestore() }
        applyPackageRestore(validated)
        try await saveAndWait()
    }
}

public enum BackupRestoreError: LocalizedError {
    case changedWhilePreparing
    public var errorDescription: String? { "准备恢复期间数据发生了变化。当前修改已保留，请重新预览并恢复。" }
}
