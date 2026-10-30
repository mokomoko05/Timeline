import Foundation

struct SyncRetirement: Codable {
    var device: String
    var retiredBy: String
    var date: Date
}

extension FolderSync {
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
