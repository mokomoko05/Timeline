import CryptoKit
import Foundation

/// 文件名包含内容摘要，写入后不再修改。增量只包含变更字段，检查点保留完整删除标记。
struct SyncBatch: Codable, Equatable, Sendable {
    var format = 2
    var device: String
    var name: String
    var sequence: Int
    var base: Int
    var checkpoint: Bool
    var exportedAt: Date
    var records: [String: SyncRecord]
    var seen: [String: Int]
}

struct SyncReceipt: Codable, Equatable, Sendable {
    var device: String
    var name: String
    var date: Date
    var seen: [String: Int]
    var serial: Int?
    var imageLease: String?
    var capabilities: [String]?
}

struct IncrementalState: Codable, Equatable, Sendable {
    var deviceID: String?
    var folderPath: String?
    var commitID: String?
    var revision = 0
    var sequence = 0
    var checkpointSequence = 0
    var deltaCount = 0
    var deltaBytes = 0
    var received: [String: Int] = [:]
    var peers: [String: SyncReceipt] = [:]
    var pending: [SyncBatch] = []
    var lastBatch: String?
    var receiptFiles: [String: String] = [:]
    var publishedReceipt: String?
    var migrated: Set<String> = []
    var uploadedImages: Set<String> = []
    var queuedImages: Set<String>?
    var pendingCloud: Set<String> = []
    var receiptSerial: Int?
    var markerPublished: Bool?
    var imageLease: String?
    var protectedImagesDigest: String?
    var protectedImages: Set<String>?
    var lastImageInventory: Date?
    var imageInventoryComplete: Bool?
    var lastLeasePublication: Date?
    var lastMaintenance: Date?
    var imageCandidates: [String: Date]?
    var streamErrors: [String: String]?
    var attachmentErrors: [String: String]?
    var pendingRetirements: [String: SyncRetirement]?
    var retiredDevices: Set<String>?
    var waitingFiles: Set<String>?
    var missingImages: Set<String>?
}

enum IncrementalSync {
    static let directory = "streams"
    static let receipts = "receipts"
    static let checkpointInterval = 64
    static let checkpointBytes = 16 * 1024 * 1024

    struct ReadResult {
        var changed = false
        var waiting = false
        var bytes = 0
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    static func fileName(_ batch: SyncBatch, data: Data) -> String {
        String(format: "%016lld", Int64(batch.sequence)) + (batch.checkpoint ? "-c-" : "-d-") + digest(data) + ".json"
    }

    /// 仅发出本机产生的字段；导入其他设备的字段只写回执，冲突合并产生的新字段仍会发出。
    static func patch(from previous: [String: SyncRecord], to current: [String: SyncRecord], device: String) -> [String: SyncRecord] {
        var result: [String: SyncRecord] = [:]
        for (key, record) in current {
            var delta = SyncRecord()
            for (name, field) in record.fields where field.stamp.device == device && previous[key]?.fields[name] != field {
                delta.fields[name] = field
            }
            if let deleted = record.deleted, deleted.device == device, deleted != previous[key]?.deleted { delta.deleted = deleted }
            if !delta.fields.isEmpty || delta.deleted != nil { result[key] = delta }
        }
        return result
    }

    /// 在写云端前随本地状态一起持久化。失败重试保持同一序号、同一字节，不丢失待发送字段。
    static func prepare(state: inout IncrementalState, previous: [String: SyncRecord], records: [String: SyncRecord],
                        device: String, name: String, now: Date) throws {
        let changes = patch(from: previous, to: records, device: device)
        guard state.sequence == 0 || !changes.isEmpty else { return }
        let bytes = try encode(changes).count
        let checkpoint = state.sequence == 0 || state.deltaCount >= checkpointInterval - 1 || (state.deltaCount >= 8 && state.deltaBytes + bytes >= checkpointBytes)
        let batch = SyncBatch(device: device, name: name, sequence: state.sequence + 1, base: state.sequence,
                              checkpoint: checkpoint, exportedAt: now, records: checkpoint ? records : changes, seen: state.received)
        state.sequence = batch.sequence
        if checkpoint {
            state.checkpointSequence = batch.sequence
            state.deltaCount = 0
            state.deltaBytes = 0
        } else {
            state.deltaCount += 1
            state.deltaBytes += bytes
        }
        state.pending.append(batch)
        state.received[device] = state.sequence
    }

    static func read(folder: URL, device: String, state: inout IncrementalState,
                     merge: inout SyncMerge, records: inout [String: SyncRecord], quiet: Set<String> = []) throws -> ReadResult {
        var result = ReadResult()
        state.streamErrors = [:]
        state.waitingFiles = []
        let root = folder.appendingPathComponent(directory)
        if FileManager.default.fileExists(atPath: root.path) {
            for peer in try FolderSync.coordinatedDirectoryContents(root).map(\.lastPathComponent).sorted() where safe(peer) && peer != device {
                let reported = (result.waiting, state.waitingFiles, state.streamErrors)
                defer { if quiet.contains(peer) { (result.waiting, state.waitingFiles, state.streamErrors) = reported } }
                var problemPath = "streams/" + peer
                do {
                    let path = root.appendingPathComponent(peer)
                    guard (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    let (files, waiting) = try list(path)
                    result.waiting = result.waiting || waiting
                    let parsed = files.compactMap { url -> (URL, Int, Bool)? in
                        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
                        guard parts.count == 3, let sequence = Int(parts[0]), sequence > 0,
                              parts[1] == "c" || parts[1] == "d", parts[2].count == 64 else { return nil }
                        return (url, sequence, parts[1] == "c")
                    }.sorted { $0.1 < $1.1 }
                    var received = state.received[peer] ?? 0
                    // 新检查点完整覆盖早期增量，可以跨过已清理或尚未下载的旧批次。
                    let newest = parsed.filter { $0.2 && $0.1 > received }.last?.1
                    var sequences = Set<Int>()
                    for (file, sequence, checkpoint) in parsed where sequence > received {
                        problemPath = "streams/" + peer + "/" + file.lastPathComponent
                        if let newest, sequence < newest { continue }
                        guard sequences.insert(sequence).inserted else { throw CocoaError(.fileReadCorruptFile) }
                        if !checkpoint && sequence != received + 1 { state.waitingFiles?.insert("streams/" + peer + "/sequence-" + String(received + 1)); result.waiting = true; continue }
                        guard try available(file) else { state.waitingFiles?.insert(problemPath); result.waiting = true; continue }
                        guard let data = try FolderSync.coordinatedRead(file) else { state.waitingFiles?.insert(problemPath); result.waiting = true; continue }
                        result.bytes += data.count
                        let hash = file.deletingPathExtension().lastPathComponent.split(separator: "-").last.map(String.init)
                        guard hash == digest(data) else { throw CocoaError(.fileReadCorruptFile) }
                        let batch = try JSONDecoder().decode(SyncBatch.self, from: data)
                        guard batch.format == 2 else { throw FolderSync.SyncError.newerFormat(batch.name) }
                        guard batch.device == peer, batch.sequence == sequence, batch.checkpoint == checkpoint,
                              checkpoint || batch.base == received else { throw CocoaError(.fileReadCorruptFile) }
                        state.migrated.insert(peer)
                        merge.describeDevice = { [peers = state.peers] in peers[$0]?.name ?? $0 }
                        if merge.merge(batch.records, into: &records) { result.changed = true }
                        received = sequence
                        state.received[peer] = received
                        let receipt = SyncReceipt(device: peer, name: batch.name, date: batch.exportedAt, seen: batch.seen)
                        state.peers[peer] = combine(state.peers[peer], receipt)
                    }
                } catch {
                    state.streamErrors?[problemPath] = error.localizedDescription
                    result.waiting = true
                }
            }
        }
        let receiptRoot = folder.appendingPathComponent(receipts)
        if FileManager.default.fileExists(atPath: receiptRoot.path) {
            let (files, _) = try list(receiptRoot)
            // 回执使用持久化递增序号；系统时钟回拨也不会覆盖或漏读。
            let groups = Dictionary(grouping: files.filter { $0.lastPathComponent.split(separator: "-").count == 3 }) {
                String($0.lastPathComponent.split(separator: "-")[0])
            }
            for (peer, files) in groups where peer != device {
                let reported = (result.waiting, state.waitingFiles, state.streamErrors)
                defer { if quiet.contains(peer) { (result.waiting, state.waitingFiles, state.streamErrors) = reported } }
                var problemPath = "receipts/" + peer
                do {
                    guard let file = files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).last,
                          state.receiptFiles[peer] != file.lastPathComponent else { continue }
                    problemPath = "receipts/" + file.lastPathComponent
                    guard try available(file), let data = try FolderSync.coordinatedRead(file) else { state.waitingFiles?.insert(problemPath); result.waiting = true; continue }
                    result.bytes += data.count
                    guard file.deletingPathExtension().lastPathComponent.hasSuffix(digest(data)) else { throw CocoaError(.fileReadCorruptFile) }
                    let receipt = try JSONDecoder().decode(SyncReceipt.self, from: data)
                    guard receipt.device == peer else { throw CocoaError(.fileReadCorruptFile) }
                    state.receiptFiles[peer] = file.lastPathComponent
                    state.peers[peer] = combine(state.peers[peer], receipt)
                } catch {
                    state.streamErrors?[problemPath] = error.localizedDescription
                    result.waiting = true
                }
            }
        }
        if state.peers.values.contains(where: { !quiet.contains($0.device) && ($0.seen[$0.device] ?? 0) > (state.received[$0.device] ?? 0) }) { result.waiting = true }
        return result
    }

    private static func combine(_ prior: SyncReceipt?, _ incoming: SyncReceipt) -> SyncReceipt {
        guard let prior else { return incoming }
        var result = incoming.serial == nil && prior.serial != nil ? prior : incoming
        for (device, sequence) in prior.seen { result.seen[device] = max(result.seen[device] ?? 0, sequence) }
        for (device, sequence) in incoming.seen { result.seen[device] = max(result.seen[device] ?? 0, sequence) }
        return result
    }

    struct Publication {
        var url: URL
        var bytes: Int
        var batches: Int
    }

    static func publish(folder: URL, device: String, name: String, now: Date, state: inout IncrementalState) throws -> Publication {
        let root = folder.appendingPathComponent(directory).appendingPathComponent(device)
        var written = 0
        let count = state.pending.count
        for batch in state.pending {
            let data = try encode(batch)
            let file = fileName(batch, data: data)
            let url = root.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: url.path) { try FolderSync.coordinatedWrite(data, to: url); written += data.count }
            state.lastBatch = file
            state.pendingCloud.insert(directory + "/" + device + "/" + file)
        }
        state.pending = []
        // 回执只随接收位置变化更新；普通轮询不写文件，也不刷新确认时间。
        let signature = digest(try encode(state.received)) + (state.imageLease ?? "") + ":device-retirement-v1"
        let receiptRoot = folder.appendingPathComponent(receipts)
        if state.publishedReceipt?.contains(signature) != true {
            state.receiptSerial = (state.receiptSerial ?? 0) + 1
            let receipt = SyncReceipt(device: device, name: name, date: now, seen: state.received,
                                      serial: state.receiptSerial, imageLease: state.imageLease, capabilities: ["device-retirement-v1"])
            let data = try encode(receipt)
            let file = device + "-" + String(format: "%016lld", Int64(state.receiptSerial ?? 1)) + "-" + digest(data) + ".json"
            try FolderSync.coordinatedWrite(data, to: receiptRoot.appendingPathComponent(file))
            state.publishedReceipt = signature + ":" + file
            state.pendingCloud.insert(receipts + "/" + file)
            written += data.count
        }
        if state.markerPublished != true {
            let marker = SyncSnapshot(format: 2, device: device, name: name, exportedAt: now, records: [:])
            let data = try encode(marker)
            try FolderSync.coordinatedWrite(data, to: FolderSync.snapshotURL(folder, device))
            state.markerPublished = true
            written += data.count
            state.pendingCloud.insert(FolderSync.devicesFolder + "/" + device + ".json")
        }
        guard let batch = state.lastBatch else { throw CocoaError(.fileNoSuchFile) }
        return Publication(url: root.appendingPathComponent(batch), bytes: written, batches: count)
    }

    /// 已上传检查点接管旧批次后才清理。旧设备离线时仍可从保留的检查点补齐，不依赖被删除的增量。
    static func compact(folder: URL, device: String, uploadPending: (URL) throws -> Bool) throws {
        let root = folder.appendingPathComponent(directory).appendingPathComponent(device)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let (files, _) = try list(root)
        let checkpoints = files.filter { $0.lastPathComponent.contains("-c-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        if checkpoints.count >= 2, !(try uploadPending(checkpoints[0])), !(try uploadPending(checkpoints[1])),
           let cutoff = Int(checkpoints[1].lastPathComponent.prefix(16)) {
            for file in files {
                if let sequence = Int(file.lastPathComponent.prefix(16)), sequence < cutoff { try? remove(file) }
            }
        }
        let receiptsRoot = folder.appendingPathComponent(receipts)
        if FileManager.default.fileExists(atPath: receiptsRoot.path) {
            let (files, _) = try list(receiptsRoot)
            let own = files.filter { $0.lastPathComponent.hasPrefix(device + "-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
            if let latest = own.first, !(try uploadPending(latest)) {
                for file in own.dropFirst(2) { try? remove(file) }
            }
        }
    }

    static func remove(_ url: URL) throws {
        var coordinationError: NSError?
        var removalError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) {
            do { try FileManager.default.removeItem(at: $0) } catch { removalError = error }
        }
        if let error = coordinationError ?? removalError { throw error }
    }

    static func safe(_ name: String) -> Bool { !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }

    static func available(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return false
        }
        let fresh = URL(fileURLWithPath: url.path)
        let values = try fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            return false
        }
        return true
    }

    static func list(_ directory: URL) throws -> ([URL], Bool) {
        let files = try FolderSync.coordinatedDirectoryContents(directory).compactMap { file -> URL? in
            let name = file.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let real = String(name.dropFirst().dropLast(7))
                return directory.appendingPathComponent(real)
            }
            return name.hasSuffix(".json") && !name.hasPrefix(".") ? directory.appendingPathComponent(name) : nil
        }
        return (files, false)
    }
}
