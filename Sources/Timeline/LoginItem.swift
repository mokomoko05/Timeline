import AppKit
import Combine

@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published var errorMessage: String?
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
        do {
            if enabled {
                guard Bundle.main.bundleURL.pathExtension == "app" else {
                    throw NSError(domain: label, code: 1, userInfo: [NSLocalizedDescriptionKey: "请先运行安装脚本，再从「应用程序」打开 Timeline。"])
                }
                let properties: [String: Any] = [
                    "Label": label,
                    "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundleURL.path],
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
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    private func launchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
