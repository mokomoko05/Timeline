import Foundation

public struct LogTimelineSegment: Equatable {
    public let focusBefore: Bool
    public let focusAfter: Bool

    public static func segments(in logs: [DailyLogEntry]) -> [UUID: Self] {
        var focused = false
        var result: [UUID: Self] = [:]
        for log in logs.sorted(by: { $0.createdAt < $1.createdAt }) {
            let before = focused
            if log.focusMarker == "FOCUS" { focused = true }
            if log.focusMarker == "END" { focused = false }
            result[log.id] = Self(focusBefore: before, focusAfter: focused)
        }
        return result
    }
}
