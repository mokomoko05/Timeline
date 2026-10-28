import AppKit

enum WindowScreenBounds {
    /// 相邻屏幕允许连续跨屏；屏幕之间的空洞、菜单栏和 Dock 不算可用区域。
    /// 保存位置已完全离屏时，回到首选屏幕。
    static func constrain(_ frame: NSRect, to areas: [NSRect], fallback: NSRect?) -> NSRect {
        let areas = areas.filter { !$0.isEmpty && !$0.isInfinite }
        guard !areas.isEmpty else { return frame }
        let best = areas.max { overlap(frame, $0) < overlap(frame, $1) }!
        let visible = overlap(frame, best) > 0 ? best : areas.first(where: { $0 == fallback }) ?? areas[0]
        if overlap(frame, best) > 0 {
            let candidates = continuousAreas(areas).filter { $0.width >= frame.width && $0.height >= frame.height }
            if let closest = candidates.map({ clamp(frame, to: $0) }).min(by: {
                distance($0.origin, frame.origin) < distance($1.origin, frame.origin)
            }) { return closest }
        }
        return clamp(frame, to: visible)
    }

    /// 拉边时裁剪正在扩大的边缘，固定的对边不随之移动。原本超大或离屏的窗口仍保留尺寸策略。
    static func constrainResize(_ proposed: NSRect, current: NSRect, minimum: NSSize, to areas: [NSRect], fallback: NSRect?) -> NSRect {
        let candidates = continuousAreas(areas).filter { $0.contains(current) }.compactMap { area -> NSRect? in
            let clipped = proposed.intersection(area)
            guard !clipped.isNull, clipped.width >= minimum.width, clipped.height >= minimum.height else { return nil }
            return clipped
        }
        return candidates.min {
            distance($0.origin, proposed.origin) + distance(NSPoint(x: $0.maxX, y: $0.maxY), NSPoint(x: proposed.maxX, y: proposed.maxY))
                < distance($1.origin, proposed.origin) + distance(NSPoint(x: $1.maxX, y: $1.maxY), NSPoint(x: proposed.maxX, y: proposed.maxY))
        } ?? constrain(proposed, to: areas, fallback: fallback)
    }

    private static func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }

    /// 合并覆盖连续的矩形通道；不能直接取屏幕外接矩形，否则错位屏幕之间的空白也会放行。
    private static func continuousAreas(_ screens: [NSRect]) -> [NSRect] {
        var areas = screens.filter { !$0.isEmpty && !$0.isInfinite }
        var changed = true
        while changed {
            changed = false
            let previous = areas
            for (index, a) in previous.enumerated() {
                for b in previous.dropFirst(index + 1) {
                    let x0 = max(a.minX, b.minX), x1 = min(a.maxX, b.maxX)
                    let y0 = max(a.minY, b.minY), y1 = min(a.maxY, b.maxY)
                    guard x0 <= x1, y0 <= y1 else { continue }
                    let merged = [NSRect(x: min(a.minX, b.minX), y: y0, width: max(a.maxX, b.maxX) - min(a.minX, b.minX), height: y1 - y0),
                                  NSRect(x: x0, y: min(a.minY, b.minY), width: x1 - x0, height: max(a.maxY, b.maxY) - min(a.minY, b.minY))]
                    for candidate in merged where !candidate.isEmpty && !areas.contains(where: { $0.contains(candidate) }) {
                        areas.removeAll { candidate.contains($0) }
                        areas.append(candidate)
                        changed = true
                    }
                }
            }
        }
        return areas
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
