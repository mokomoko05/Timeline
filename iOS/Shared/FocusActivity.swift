import ActivityKit
import Foundation

/// 专注计时的实时活动（锁屏和灵动岛）。应用和小组件扩展共用这一份定义。
/// 文字由应用按当前界面语言算好放进来，扩展里不用再做本地化。
struct FocusActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 计时中：倒计时到这一刻结束（暂停的时间已经顺延进去）。
        var endsAt: Date
        /// 暂停或时间到时停住的剩余秒数；计时中为 nil。
        var frozenRemaining: TimeInterval?
        /// 「专注中」「已暂停」「时间到」。
        var status: String
        var finished: Bool
    }

    var title: String
    var number: Int?
    var plannedSeconds: TimeInterval
}

extension FocusActivityAttributes.ContentState {
    var isRunning: Bool { frozenRemaining == nil && !finished }

    /// 停住时显示的「mm:ss」。
    var frozenText: String {
        let total = max(0, Int((frozenRemaining ?? 0).rounded()))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
