import Foundation

/// 外部文档目录在前台同步期间保持授权和文件呈现关系，而不是每次轮询后就关闭。
/// 回调只请求一次防抖检查，不在文件协调队列里读写文件或等待主线程。
final class SyncFolderAccess: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let changed: @Sendable () -> Void
    private let ownDevice: String?
    private let lock = NSLock()
    private var registered = false
    private var scoped = false

    init(folder: URL, ownDevice: String? = nil, changed: @escaping @Sendable () -> Void) {
        presentedItemURL = folder
        self.ownDevice = ownDevice
        self.changed = changed
        let queue = OperationQueue()
        queue.name = "Timeline sync folder changes"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        super.init()
    }

    func start() {
        lock.lock()
        guard !registered else { lock.unlock(); return }
        scoped = presentedItemURL?.startAccessingSecurityScopedResource() == true
        registered = true
        lock.unlock()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        lock.lock()
        guard registered else { lock.unlock(); return }
        registered = false
        let wasScoped = scoped
        scoped = false
        lock.unlock()
        // 不能持锁调用：系统可能等回调队列，而回调 `notify()` 也要拿这把锁。
        NSFileCoordinator.removeFilePresenter(self)
        if wasScoped { presentedItemURL?.stopAccessingSecurityScopedResource() }
    }

    deinit { stop() }

    private func notify(_ url: URL? = nil) {
        if let url, isOwnPublication(url) { return }
        lock.lock()
        let active = registered
        lock.unlock()
        if active { changed() }
    }

    /// 本机发布不可变增量和回执时也会收到文件通知；不把自己的写入当成远端更新再同步一次。
    func isOwnPublication(_ url: URL) -> Bool {
        guard let ownDevice, let root = presentedItemURL else { return false }
        let components = url.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents
        guard components.starts(with: base) else { return false }
        let relative = Array(components.dropFirst(base.count))
        guard relative.count >= 2 else { return false }
        switch relative[0] {
        case "streams": return relative[1] == ownDevice
        case "receipts": return relative[1].hasPrefix(ownDevice + "-")
        case "devices", "updates": return relative[1] == ownDevice + ".json"
        default: return false
        }
    }

    func presentedItemDidChange() { notify() }
    func presentedSubitemDidAppear(at url: URL) { notify(url) }
    func presentedSubitemDidChange(at url: URL) { notify(url) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        if !isOwnPublication(oldURL) || !isOwnPublication(newURL) { notify() }
    }
    func presentedItemDidChangeUbiquityAttributes(_ attributes: Set<URLResourceKey>) { notify() }
}
