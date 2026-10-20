import AppKit
import TimelineCore

enum LegacyPreferencesMigration {
    static let marker = "timelineLegacyPreferencesMigrated"

    static func copy(_ legacy: [String: Any], into defaults: UserDefaults) {
        guard !defaults.bool(forKey: marker) else { return }
        for (key, value) in legacy {
            let migratedKey = key.replacingOccurrences(of: "Dayleaf", with: "Timeline")
                .replacingOccurrences(of: "dayleaf", with: "timeline")
            if defaults.object(forKey: migratedKey) == nil { defaults.set(value, forKey: migratedKey) }
        }
        defaults.set(true, forKey: marker)
    }
}

@MainActor
enum LegacyMigration {
    static func run(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "local.dayleaf.app" }) {
            throw NSError(domain: "local.timeline.app", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: AppLocalized("请先退出 Scheduler 或 Dayleaf，再打开 Timeline。旧应用和数据会保留。")])
        }
        if !["TIMELINE_DATA_DIR", "DAYLEAF_DATA_DIR"].contains(where: { environment[$0]?.isEmpty == false }) {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            _ = try JournalStore.migrateLegacyDirectory(applicationSupport: support)
        }
        let defaults = UserDefaults.standard
        LegacyPreferencesMigration.copy(defaults.persistentDomain(forName: "local.dayleaf.app") ?? [:], into: defaults)
        guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
    }
}
