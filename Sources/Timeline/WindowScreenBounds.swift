import AppKit

enum WindowScreenBounds {
    /// 取重叠面积最大的屏幕；保存位置已完全离屏时，回到首选屏幕。
    static func constrain(_ frame: NSRect, to areas: [NSRect], fallback: NSRect?) -> NSRect {
        let areas = areas.filter { !$0.isEmpty && !$0.isInfinite }
        guard !areas.isEmpty else { return frame }
        let best = areas.max { overlap(frame, $0) < overlap(frame, $1) }!
        let visible = overlap(frame, best) > 0 ? best : areas.first(where: { $0 == fallback }) ?? areas[0]
        return clamp(frame, to: visible)
    }

    private static func overlap(_ frame: NSRect, _ area: NSRect) -> CGFloat {
        let intersection = frame.intersection(area)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    /// 保持用户选定的尺寸；比屏幕还大的窗口保留左上角可操作区域。
    static func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = max(min(frame.origin.x, visible.maxX - frame.width), visible.minX)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        return frame
    }
}
