import AppKit
import Combine

@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published var errorMessage: String?
    @Published private(set) var isUpdating = false
    private let label = "local.timeline.app"
    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    init() { refresh() }

    func refresh() {
        enabled = FileManager.default.fileExists(atPath: agentURL.path)
    }

    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        isUpdating = true
        let url = agentURL, bundleURL = Bundle.main.bundleURL, label = label
        Task { [weak self] in
            let error = await Task.detached(priority: .utility) {
                Self.configure(enabled, agentURL: url, bundleURL: bundleURL, label: label)
            }.value
            guard let self else { return }
            errorMessage = error
            refresh()
            isUpdating = false
        }
    }

    /// 安装命令尚未启动 AppKit 事件循环，可以同步配置；桌面交互始终走后台。
    func configureForInstallation() {
        errorMessage = Self.configure(true, agentURL: agentURL, bundleURL: Bundle.main.bundleURL, label: label)
        refresh()
    }

    nonisolated private static func configure(_ enabled: Bool, agentURL: URL, bundleURL: URL, label: String) -> String? {
        do {
            if enabled {
                guard bundleURL.pathExtension == "app" else {
                    throw NSError(domain: label, code: 1, userInfo: [NSLocalizedDescriptionKey: "请先运行安装脚本，再从「应用程序」打开 Timeline。"])
                }
                let properties: [String: Any] = [
                    "Label": label,
                    "ProgramArguments": ["/usr/bin/open", "-g", bundleURL.path],
                    "RunAtLoad": true,
                    "LimitLoadToSessionType": "Aqua"
                ]
                try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
                try data.write(to: agentURL, options: .atomic)
                _ = try launchctl(["bootout", "gui/\(getuid())/\(label)"])
                let result = try launchctl(["bootstrap", "gui/\(getuid())", agentURL.path])
                guard result == 0 else {
                    throw NSError(domain: label, code: Int(result), userInfo: [NSLocalizedDescriptionKey: "已保存登录启动配置，但系统暂未加载（\(result)）。下次登录将重试。"])
                }
            } else {
                if FileManager.default.fileExists(atPath: agentURL.path) {
                    try FileManager.default.removeItem(at: agentURL)
                }
                _ = try launchctl(["bootout", "gui/\(getuid())/\(label)"])
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    nonisolated private static func launchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try runProcess(process)
    }

    nonisolated static func runProcess(_ process: Process, timeout: TimeInterval = 5) throws -> Int32 {
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            throw NSError(domain: "local.timeline.app", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "登录启动配置超时，请稍后重试。"])
        }
        return process.terminationStatus
    }
}
