import Combine
import Foundation

/// 导入由草稿持有，关闭视图不取消；丢弃草稿递增代次，迟到结果不能写进新草稿。
@MainActor
public final class ImageImportQueue: ObservableObject {
    @Published public private(set) var pending = 0
    @Published public private(set) var errorMessage: String?
    private var generation = UUID()
    private var tail: Task<Void, Never>?

    public init() {}

    public enum ImportError: LocalizedError {
        case pending
        public var errorDescription: String? { "图片正在导入，请完成后再保存。" }
    }

    public func requireReady() throws {
        if pending > 0 { throw ImportError.pending }
    }

    public func invalidate() {
        generation = UUID()
        tail = nil
        pending = 0
        errorMessage = nil
    }

    /// 在创建异步任务之前登记，快速粘贴后立即按回车也不能越过。
    public func start(_ operation: @escaping @MainActor () async throws -> [String],
                      append: @escaping @MainActor ([String]) -> Void) {
        let token = generation
        pending += 1
        errorMessage = nil
        let previous = tail
        tail = Task {
            await previous?.value
            // 同一草稿按选择顺序处理，限制同时读取的大原图数量。
            guard generation == token else { return }
            do {
                let names = try await operation()
                if generation == token { append(names) }
            } catch {
                if generation == token { errorMessage = error.localizedDescription }
            }
            if generation == token { pending -= 1 }
        }
    }
}

extension JournalStore {
    public func imageImports(for key: String) -> ImageImportQueue {
        if let queue = draftImageImports[key] { return queue }
        let queue = ImageImportQueue()
        draftImageImports[key] = queue
        return queue
    }
}
