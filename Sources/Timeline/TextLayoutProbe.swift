import Foundation
import QuartzCore

enum TextLayoutProbe {
    static let enabled = ProcessInfo.processInfo.environment["TIMELINE_LAYOUT_DIAGNOSTICS"] == "1"

    struct Snapshot: Codable {
        let counts: [String: Int]
        let milliseconds: [String: Double]
        let proposedWidths: [String: Int]
    }

    private static var counts: [String: Int] = [:]
    private static var milliseconds: [String: Double] = [:]
    private static var proposedWidths: [String: Int] = [:]
    private static let lock = NSLock()

    static func reset() {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        counts.removeAll(keepingCapacity: true)
        milliseconds.removeAll(keepingCapacity: true)
        proposedWidths.removeAll(keepingCapacity: true)
    }

    static func count(_ name: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        counts[name, default: 0] += 1
    }

    static func proposal(_ width: CGFloat?) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        counts["sizeProposals", default: 0] += 1
        let key = width.map { $0.isFinite ? String(format: "%.1f", $0) : "infinite" } ?? "unspecified"
        proposedWidths[key, default: 0] += 1
    }

    static func start() -> CFTimeInterval? { enabled ? CACurrentMediaTime() : nil }

    static func end(_ name: String, since start: CFTimeInterval?) {
        guard let start else { return }
        lock.lock()
        defer { lock.unlock() }
        milliseconds[name, default: 0] += (CACurrentMediaTime() - start) * 1000
    }

    static func snapshot() -> Snapshot? {
        guard enabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(counts: counts, milliseconds: milliseconds, proposedWidths: proposedWidths)
    }

    static func report(_ label: String) {
        guard let snapshot = snapshot(), let data = try? JSONEncoder().encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return }
        print("TEXT LAYOUT \(label) \(json)")
    }
}
