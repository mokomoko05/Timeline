import Foundation

struct SyncRetirement: Codable, Equatable, Sendable {
    var device: String
    var retiredBy: String
    var date: Date
}

extension FolderSync {
    /// 与正文 outbox 一起持久化的完整操作；失败后下轮/重启继续，成功后不重复改写标记。
    nonisolated static func publishRetirements(folder: URL, ledger: inout IncrementalState) {
        for (id, marker) in ledger.pendingRetirements ?? [:] {
            let relative = "retired-devices/" + id + ".json"
            do {
                guard IncrementalSync.safe(id), marker.device == id else { throw CocoaError(.fileWriteInvalidFileName) }
                let url = folder.appendingPathComponent(relative)
                let data = try IncrementalSync.encode(marker)
                if try !FileManager.default.fileExists(atPath: url.path) || coordinatedRead(url) != data {
                    try coordinatedWrite(data, to: url)
                }
                ledger.pendingCloud.insert(relative)
                ledger.pendingRetirements?.removeValue(forKey: id)
            } catch { ledger.attachmentErrors?[relative] = error.localizedDescription }
        }
    }

    nonisolated static func retiredDevices(in folder: URL) throws -> RetirementInventory {
        let directory = folder.appendingPathComponent("retired-devices")
        guard FileManager.default.fileExists(atPath: directory.path) else { return RetirementInventory() }
        var result = RetirementInventory()
        let (files, _) = try IncrementalSync.list(directory)
        for file in files {
            let path = "retired-devices/" + file.lastPathComponent
            do {
                let id = file.deletingPathExtension().lastPathComponent
                guard IncrementalSync.safe(id) else { throw CocoaError(.fileReadCorruptFile) }
                guard try IncrementalSync.available(file), let data = try coordinatedRead(file) else { result.waiting.insert(path); continue }
                let marker = try JSONDecoder().decode(SyncRetirement.self, from: data)
                guard marker.device == id, IncrementalSync.safe(marker.retiredBy) else { throw CocoaError(.fileReadCorruptFile) }
                result.devices.insert(id)
            } catch { result.errors[path] = error.localizedDescription }
        }
        return result
    }
}

struct RetirementInventory {
    var devices: Set<String> = []
    var errors: [String: String] = [:]
    var waiting: Set<String> = []
}
