import Foundation

/// 同步记录里的 JSON 值：模型先按自己的 Codable 编码成 JSON，再逐字段比较、合并。
public enum SyncValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([SyncValue])
    case object([String: SyncValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([SyncValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: SyncValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    static func encoding<Value: Encodable>(_ value: Value) throws -> SyncValue {
        try JSONDecoder().decode(SyncValue.self, from: JSONEncoder().encode(value))
    }

    func decoded<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    var fields: [String: SyncValue] {
        if case .object(let fields) = self { return fields }
        return [:]
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

/// 一次修改的时间戳：时间相同（极少见）时按设备编号决定先后，保证每台设备合并出同样的结果。
public struct SyncStamp: Codable, Hashable, Comparable, Sendable {
    public var time: Double
    public var device: String

    public static func < (lhs: SyncStamp, rhs: SyncStamp) -> Bool {
        lhs.time == rhs.time ? lhs.device < rhs.device : lhs.time < rhs.time
    }

    private enum CodingKeys: String, CodingKey { case time = "t", device = "d" }
}

/// 记录里的一个字段：值和最后一次修改它的时间戳。
/// 长文本（工作板、每日小结）另记 `seen`：这个值已经包含了各设备到哪一刻为止的修改，用来分辨两台设备是不是各改各的。
public struct SyncField: Codable, Equatable, Sendable {
    public var value: SyncValue
    public var stamp: SyncStamp
    public var seen: [String: Double]?

    private enum CodingKeys: String, CodingKey { case value = "v", time = "t", device = "d", seen = "s" }

    init(value: SyncValue, stamp: SyncStamp, seen: [String: Double]? = nil) {
        self.value = value
        self.stamp = stamp
        self.seen = seen
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = try values.decode(SyncValue.self, forKey: .value)
        stamp = SyncStamp(time: try values.decode(Double.self, forKey: .time), device: try values.decode(String.self, forKey: .device))
        seen = try values.decodeIfPresent([String: Double].self, forKey: .seen)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(value, forKey: .value)
        try values.encode(stamp.time, forKey: .time)
        try values.encode(stamp.device, forKey: .device)
        try values.encodeIfPresent(seen, forKey: .seen)
    }

    /// 这个值已经包含了 `other` 那次修改（是在它的基础上改的）。
    func includes(_ other: SyncField) -> Bool {
        stamp == other.stamp || (seen?[other.stamp.device]).map { $0 >= other.stamp.time } == true
    }
}

/// 一条同步记录（一个待办、一条日志、一页工作板……）：各字段独立合并，删除也是带时间戳的修改。
/// 删除之后又有更晚的字段修改（另一台设备同时在改，或者撤销了删除），记录就算还在。
public struct SyncRecord: Codable, Equatable, Sendable {
    public var fields: [String: SyncField] = [:]
    public var deleted: SyncStamp?

    private enum CodingKeys: String, CodingKey { case fields = "f", deleted = "x" }

    public var isAlive: Bool {
        guard let deleted else { return !fields.isEmpty }
        return fields.values.contains { $0.stamp > deleted }
    }

    var latest: SyncStamp? { ([deleted].compactMap { $0 } + fields.values.map(\.stamp)).max() }

    /// 去掉空值后的字段，用来还原模型。
    var values: [String: SyncValue] { fields.compactMapValues { $0.value == .null ? nil : $0.value } }
}

/// 合并时的上下文：本机编号、当前时间，以及哪些字段是要保留冲突内容的长文本。
struct SyncMerge {
    var device: String
    var now: Date
    var describeDevice: (String) -> String = { $0 }

    /// 两边各自改过就把两份都留下的长文本字段（键的前缀 → 字段名）。
    static let textFields: [String: String] = ["board/": "markdown", "summary/": "text"]

    static func isTextField(record key: String, field: String) -> Bool {
        textFields.contains { key.hasPrefix($0.key) && $0.value == field }
    }

    /// 本机的新时间戳：不早于记录里已有的任何修改，保证本机刚做的修改一定排在它所基于的版本之后。
    func stamp(after record: SyncRecord?) -> SyncStamp {
        var time = (now.timeIntervalSince1970 * 1000).rounded() / 1000
        if let latest = record?.latest, latest.time >= time { time = latest.time + 0.001 }
        return SyncStamp(time: time, device: device)
    }

    /// 把本机当前的内容和上次同步时的状态比较：改了的字段、新建和删除的记录盖上本机的新时间戳。
    @discardableResult
    func stampLocalChanges(_ current: [String: [String: SyncValue]], into state: inout [String: SyncRecord]) -> Bool {
        var changed = false
        for (key, fields) in current {
            var record = state[key] ?? SyncRecord()
            let alive = record.isAlive
            var edits: [String: SyncValue] = [:]
            for (name, value) in fields where !alive || record.fields[name]?.value != value { edits[name] = value }
            for (name, field) in record.fields where fields[name] == nil && (!alive || field.value != .null) { edits[name] = .null }
            guard !edits.isEmpty else { continue }
            let stamp = stamp(after: record)
            for (name, value) in edits {
                var seen: [String: Double]?
                if Self.isTextField(record: key, field: name) {
                    seen = record.fields[name].map { $0.seen ?? [$0.stamp.device: $0.stamp.time] } ?? [:]
                    seen![device] = stamp.time
                }
                record.fields[name] = SyncField(value: value, stamp: stamp, seen: seen)
            }
            state[key] = record
            changed = true
        }
        for (key, record) in state where current[key] == nil && record.isAlive {
            state[key]!.deleted = stamp(after: record)
            changed = true
        }
        return changed
    }

    /// 把另一台设备的状态合进来；返回本机状态有没有变化。
    @discardableResult
    func merge(_ remote: [String: SyncRecord], into state: inout [String: SyncRecord]) -> Bool {
        var changed = false
        for (key, theirs) in remote {
            guard let ours = state[key] else { state[key] = theirs; changed = true; continue }
            guard ours != theirs else { continue }
            var merged = ours
            merged.deleted = [ours.deleted, theirs.deleted].compactMap { $0 }.max()
            for (name, field) in theirs.fields {
                guard let mine = ours.fields[name] else { merged.fields[name] = field; continue }
                merged.fields[name] = mergeField(mine, field, record: key, name: name, base: merged)
            }
            if merged != ours { state[key] = merged; changed = true }
        }
        return changed
    }

    private func mergeField(_ mine: SyncField, _ theirs: SyncField, record key: String, name: String, base: SyncRecord) -> SyncField {
        guard mine != theirs else { return mine }
        let winner = mine.stamp == theirs.stamp ? (mine.value.sortKey >= theirs.value.sortKey ? mine : theirs) : (mine.stamp < theirs.stamp ? theirs : mine)
        let loser = winner == mine ? theirs : mine
        guard Self.isTextField(record: key, field: name), mine.seen != nil || theirs.seen != nil else { return winner }
        var seen = mine.seen ?? [mine.stamp.device: mine.stamp.time]
        for (device, time) in theirs.seen ?? [theirs.stamp.device: theirs.stamp.time] { seen[device] = max(seen[device] ?? time, time) }
        // 同样的内容（比如两台设备各自生成了同一份冲突合并结果）：取较晚的那份，记下两边见过的修改。
        if mine.value == theirs.value { return SyncField(value: winner.value, stamp: winner.stamp, seen: seen) }
        // 一边是在另一边的基础上改的：正常覆盖。
        if winner.includes(loser) { return winner }
        if loser.includes(winner) { return loser }
        // 两边各改各的：较晚的放前面，另一份接在冲突标记后面，谁也不丢；结果算本机的一次新修改，同步回去。
        let first = winner.value.string ?? "", second = loser.value.string ?? ""
        if first.contains(second) { return SyncField(value: winner.value, stamp: winner.stamp, seen: seen) }
        let text = first + "\n\n" + Self.conflictMarker(for: loser.stamp, device: describeDevice(loser.stamp.device)) + "\n\n" + second
        let stamp = stamp(after: base)
        seen[device] = stamp.time
        return SyncField(value: .string(text), stamp: stamp, seen: seen)
    }

    static func conflictMarker(for stamp: SyncStamp, device: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "——— 同步冲突：以下是 \(device) 在 \(formatter.string(from: Date(timeIntervalSince1970: stamp.time))) 的版本 ———"
    }
}

private extension SyncValue {
    /// 时间戳完全相同时的兜底排序：任意但确定。
    var sortKey: String { (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "" }
}
