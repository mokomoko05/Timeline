import Foundation

/// 从一行输入中识别日期、时间、提醒和重复规则，例如「周五 下午3点 评审 提前30分钟」。
public struct QuickAdd: Equatable {
    public var title: String
    public var day: Date?
    public var hour: Int?
    public var minute = 0
    public var reminderMinutes: Int?
    public var repeatRule: RepeatRule = .none
    public var tags: [String] = []

    public var hasSchedule: Bool { day != nil || hour != nil || reminderMinutes != nil || repeatRule != .none }

    /// 生成待办与它所属的安排日期。没有明确日期时使用 `defaultDay`；只有写了日期或时间才会设置截止。
    public func resolve(defaultDay: Date, defaultDue: Bool = false) -> (day: Date, todo: Todo) {
        let calendar = JournalDates.calendar
        let scheduled = calendar.startOfDay(for: day ?? defaultDay)
        var todo = Todo(title: title)
        if let hour {
            todo.dueDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: scheduled)
            todo.dueHasTime = true
        } else if day != nil || defaultDue {
            todo.dueDate = scheduled
        }
        if todo.dueDate != nil { todo.reminderMinutes = reminderMinutes }
        todo.repeatRule = repeatRule
        todo.tags = tags
        if repeatRule == .monthly { todo.repeatMonthDay = calendar.component(.day, from: scheduled) }
        return (scheduled, todo)
    }

    public static func parse(_ text: String, now: Date = Date()) -> QuickAdd {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var (work, links) = mask(original)
        var result = QuickAdd(title: original)
        // 标签先取走，免得「#周五」被当成日期。
        result.tags = TagText.take(from: &work)
        let calendar = JournalDates.calendar
        let today = calendar.startOfDay(for: now)

        // 重复
        if let match = take(#"每(?:个)?(?:周|星期|礼拜)([一二三四五六日天])"#, from: &work) {
            result.repeatRule = .weekly
            result.day = upcoming(weekday: weekdayIndex(match[1]), after: today, forceNextWeek: false)
        } else if take(#"每(?:个)?工作日"#, from: &work) != nil {
            result.repeatRule = .weekdays
        } else if take(#"每(?:天|日)"#, from: &work) != nil {
            result.repeatRule = .daily
        } else if take(#"每(?:个)?(?:周|星期|礼拜)(?![一二三四五六日天])"#, from: &work) != nil {
            result.repeatRule = .weekly
        } else if let match = take(#"每个?月(?:(\d{1,2})[日号])?"#, from: &work) {
            result.repeatRule = .monthly
            if let dayText = Int(match[1]), let date = nextMonthDay(dayText, after: today) { result.day = date }
        }

        // 提醒
        if let match = take(#"提前\s*(半|一|\d+)\s*(分钟|分|小时|个小时|h|天)"#, from: &work) {
            let amount = match[1] == "半" ? 0.5 : (match[1] == "一" ? 1 : Double(match[1]) ?? 0)
            let unit: Double = match[2].hasPrefix("分") ? 1 : (match[2] == "天" ? 1440 : 60)
            result.reminderMinutes = Int(amount * unit)
        } else if take(#"(?:^|\s)提醒(?=\s|$)"#, from: &work) != nil {
            result.reminderMinutes = 0
        }

        // 日期
        if result.day == nil {
            if let match = take(#"(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})"#, from: &work),
               let date = calendar.date(from: DateComponents(year: Int(match[1]), month: Int(match[2]), day: Int(match[3]))) {
                result.day = date
            } else if let match = take(#"(\d{1,2})月(\d{1,2})[日号]"#, from: &work), let month = Int(match[1]), let day = Int(match[2]) {
                let year = calendar.component(.year, from: today)
                var date = calendar.date(from: DateComponents(year: year, month: month, day: day))
                if let current = date, current < today { date = calendar.date(from: DateComponents(year: year + 1, month: month, day: day)) }
                result.day = date
            } else if let match = take(#"(\d+)\s*(天|周)后"#, from: &work), let amount = Int(match[1]) {
                result.day = calendar.date(byAdding: .day, value: amount * (match[2] == "周" ? 7 : 1), to: today)
            } else if let match = take(#"(大后天|后天|明天|明日|今天|今日)"#, from: &work) {
                let offset = ["大后天": 3, "后天": 2, "明天": 1, "明日": 1][match[1]] ?? 0
                result.day = calendar.date(byAdding: .day, value: offset, to: today)
            } else if let match = take(#"(下|本|这)?(?:周|星期|礼拜)([一二三四五六日天])"#, from: &work) {
                let prefix = match[1]
                result.day = upcoming(weekday: weekdayIndex(match[2]), after: today, forceNextWeek: prefix == "下", thisWeek: prefix == "本" || prefix == "这")
            }
        }

        // 时间
        if let match = take(#"(上午|下午|晚上|早上|中午|凌晨|晚)?\s*(\d{1,2})[:：](\d{2})"#, from: &work),
           let hour = Int(match[2]), let minute = Int(match[3]), hour < 24, minute < 60 {
            result.hour = adjusted(hour, period: match[1])
            result.minute = minute
        } else if let match = take(#"(上午|下午|晚上|早上|中午|凌晨|晚)?\s*(\d{1,2})点(半|(\d{1,2})分?)?"#, from: &work),
                  let hour = Int(match[2]), hour < 24 {
            result.hour = adjusted(hour, period: match[1])
            result.minute = match[3] == "半" ? 30 : (Int(match[4]) ?? 0)
        }

        var title = unmask(work, links: links)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，;；:：")))
        links.removeAll()
        // 整行只剩日期词时，宁可保留原文也不生成空标题。
        if title.isEmpty { return QuickAdd(title: original) }  // 标签也一并还原为原文
        title = title.trimmingCharacters(in: .whitespaces)
        result.title = title
        return result
    }

    // MARK: - 内部

    private static func adjusted(_ hour: Int, period: String) -> Int {
        switch period {
        case "下午", "晚上", "晚": return hour < 12 ? hour + 12 : hour
        case "中午": return hour < 11 ? hour + 12 : hour
        case "上午", "早上": return hour == 12 ? 0 : hour
        default: return hour
        }
    }

    private static func weekdayIndex(_ symbol: String) -> Int {
        ["一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6][symbol] ?? 0
    }

    /// weekday: 周一 = 0。默认取今天或之后最近的那天；`thisWeek` 取本周（可能已过去），`forceNextWeek` 取下周。
    private static func upcoming(weekday: Int, after today: Date, forceNextWeek: Bool, thisWeek: Bool = false) -> Date? {
        let calendar = JournalDates.calendar
        let current = (calendar.component(.weekday, from: today) + 5) % 7
        var offset = weekday - current
        if forceNextWeek { offset = 7 - current + weekday }
        else if !thisWeek, offset < 0 { offset += 7 }
        return calendar.date(byAdding: .day, value: offset, to: today)
    }

    private static func nextMonthDay(_ day: Int, after today: Date) -> Date? {
        let calendar = JournalDates.calendar
        guard (1...31).contains(day) else { return nil }
        var month = JournalDates.monthStart(today)
        for _ in 0..<13 {
            if calendar.range(of: .day, in: .month, for: month)!.count >= day,
               let date = calendar.date(byAdding: .day, value: day - 1, to: month), date >= today { return date }
            month = calendar.date(byAdding: .month, value: 1, to: month)!
        }
        return nil
    }

    /// 用私有区字符占位，避免解析 Markdown 链接和网址里的数字。
    static func mask(_ text: String) -> (String, [String]) {
        guard let regex = try? NSRegularExpression(pattern: #"\[[^\]]*\]\([^)]*\)|(?:https?|file)://\S+"#) else { return (text, []) }
        var links: [String] = []
        var output = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: output.length)).reversed() {
            links.insert(output.substring(with: match.range), at: 0)
            output = output.replacingCharacters(in: match.range, with: "\u{E000}\u{E001}\u{E000}") as NSString
        }
        return (output as String, links)
    }

    static func unmask(_ text: String, links: [String]) -> String {
        var result = text
        for link in links {
            if let range = result.range(of: "\u{E000}\u{E001}\u{E000}") { result.replaceSubrange(range, with: link) }
        }
        return result
    }

    /// 取出并删除第一个匹配，返回各捕获组（未参与匹配的组为空字符串）。
    @discardableResult
    private static func take(_ pattern: String, from text: inout String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        let source = text as NSString
        let groups = (0..<match.numberOfRanges).map { index -> String in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
        text = source.replacingCharacters(in: match.range, with: " ")
        return groups
    }
}
