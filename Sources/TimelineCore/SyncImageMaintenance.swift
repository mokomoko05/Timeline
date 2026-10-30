import Foundation

struct SyncImageLease: Codable {
    var device: String
    var images: [String]
}

enum SyncImageMaintenance {
    static let leases = "image-leases"
    static let quarantine = "image-trash"
    static let grace: TimeInterval = 30 * 86400
    static let trashRetention: TimeInterval = 90 * 86400

    @discardableResult
    static func publish(protected: Set<String>, folder: URL, device: String, now: Date = Date(), state: inout IncrementalState) throws -> Int {
        // 当前引用由增量记录立即同步；备份/草稿保护清单每天最多更新一次。
        // 避免每新增一张照片都上传一份随图库增长的完整文件名清单。
        guard state.imageLease == nil || now.timeIntervalSince(state.lastLeasePublication ?? .distantPast) >= 86400 else { return 0 }
        let data = try IncrementalSync.encode(SyncImageLease(device: device, images: protected.sorted()))
        let digest = IncrementalSync.digest(data)
        guard state.protectedImagesDigest != digest else { state.lastLeasePublication = now; return 0 }
        let file = device + "-" + digest + ".json"
        try FolderSync.coordinatedWrite(data, to: folder.appendingPathComponent(leases).appendingPathComponent(file))
        state.lastLeasePublication = now
        state.protectedImagesDigest = digest
        state.imageLease = file
        state.pendingCloud.insert(leases + "/" + file)
        return data.count
    }

    /// 任一已知设备没有完成迁移、没有回执或尚未读到本机修改，就推迟清理。
    /// 候选连续 30 天无引用才移入隔离区，再保留 90 天；恢复引用会取消候选。
    static func collect(folder: URL, device: String, now: Date, state: inout IncrementalState,
                        uploadPending: (URL) throws -> Bool) throws {
        guard now.timeIntervalSince(state.lastMaintenance ?? .distantPast) >= 86400 else { return }
        guard state.imageInventoryComplete == true, (state.streamErrors ?? [:]).isEmpty, (state.attachmentErrors ?? [:]).isEmpty else { return }
        let manager = FileManager.default
        var known = Set(state.peers.keys)
        for directory in [FolderSync.devicesFolder, IncrementalSync.directory] {
            let path = folder.appendingPathComponent(directory)
            for name in try contents(path) {
                let id = directory == FolderSync.devicesFolder ? String(name.replacingOccurrences(of: ".icloud", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".").first ?? "") : name
                if IncrementalSync.safe(id) { known.insert(id) }
            }
        }
        known.remove(device)
        known.subtract(state.retiredDevices ?? [])
        guard state.pendingCloud.isEmpty, let ownLease = state.imageLease else { return }
        var protected = state.protectedImages ?? []
        var activeLeases = [ownLease]
        for peer in known {
            guard state.migrated.contains(peer), let receipt = state.peers[peer],
                  (receipt.seen[device] ?? 0) >= state.sequence,
                  (state.received[peer] ?? 0) >= (receipt.seen[peer] ?? 0),
                  now.timeIntervalSince(receipt.date) < 7 * 86400,
                  let lease = receipt.imageLease else { return }
            let url = folder.appendingPathComponent(leases).appendingPathComponent(lease)
            guard !lease.contains("/"), try IncrementalSync.available(url), let data = try FolderSync.coordinatedRead(url),
                  lease.hasSuffix(IncrementalSync.digest(data) + ".json") else { return }
            let inventory = try JSONDecoder().decode(SyncImageLease.self, from: data)
            guard inventory.device == peer else { return }
            protected.formUnion(inventory.images)
            activeLeases.append(lease)
        }
        state.lastMaintenance = now
        var candidates = (state.imageCandidates ?? [:]).filter { !protected.contains($0.key) }
        let images = folder.appendingPathComponent(FolderSync.imagesFolder)
        let trash = folder.appendingPathComponent(quarantine)
        try FolderSync.coordinatedCreateDirectory(trash)
        let names = try contents(images)
        for name in names where !name.hasPrefix(".") && !name.contains("/") {
            if protected.contains(name) { candidates.removeValue(forKey: name); continue }
            let first = candidates[name] ?? now
            candidates[name] = first
            let url = images.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            guard now.timeIntervalSince(first) >= grace, now.timeIntervalSince(modified) >= grace,
                  !(try uploadPending(url)), try IncrementalSync.available(url), let data = try FolderSync.coordinatedRead(url) else { continue }
            // 先保留完整隔离副本，再移除原位置；并发恢复引用时客户端也能从隔离区取回原图。
            let destination = trash.appendingPathComponent(name)
            let isolatedAt = (try? destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            // 恢复后再次删除必须重新开始保留期，不能沿用上一轮已过期的隔离副本。
            if !manager.fileExists(atPath: destination.path) || isolatedAt < first {
                try FolderSync.coordinatedWrite(data, to: destination)
            }
            if try uploadPending(destination) {
                state.pendingCloud.insert(quarantine + "/" + name)
                continue
            }
            try IncrementalSync.remove(url)
        }
        for name in try contents(trash) where !name.hasPrefix(".") {
            let url = trash.appendingPathComponent(name)
            if protected.contains(name) {
                if !manager.fileExists(atPath: images.appendingPathComponent(name).path),
                   try IncrementalSync.available(url), let data = try FolderSync.coordinatedRead(url) {
                    let restored = images.appendingPathComponent(name)
                    try FolderSync.coordinatedWrite(data, to: restored)
                    if try uploadPending(restored) { state.pendingCloud.insert(FolderSync.imagesFolder + "/" + name) }
                }
                candidates.removeValue(forKey: name)
                continue
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) >= trashRetention, !(try uploadPending(url)) { try IncrementalSync.remove(url); candidates.removeValue(forKey: name) }
        }
        state.imageCandidates = candidates
        // 回执引用的清单保留；旧清单确认上传后才清理。
        if let own = state.imageLease, !(try uploadPending(folder.appendingPathComponent(leases).appendingPathComponent(own))) {
            for file in (try? FolderSync.coordinatedDirectoryContents(folder.appendingPathComponent(leases))) ?? []
                where file.lastPathComponent.hasPrefix(device + "-") && !activeLeases.contains(file.lastPathComponent) {
                try? IncrementalSync.remove(file)
            }
        }
    }

    private static func contents(_ directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        // 无法读取目录时推迟整轮清理，不能把读取失败当成“没有其他设备或引用”。
        return try FolderSync.coordinatedDirectoryContents(directory).map(\.lastPathComponent)
    }
}
