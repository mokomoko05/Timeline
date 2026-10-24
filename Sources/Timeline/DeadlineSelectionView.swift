import AppKit
import SwiftUI
import TimelineCore

/// 日期、钟表与文本输入共享同一份值，切换日期时保留已选时间。
enum DeadlineSelection {
    static func initialDate(_ date: Date, hasTime: Bool) -> Date {
        hasTime ? date : (JournalDates.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date)
    }

    static func day(_ day: Date, keepingTime date: Date) -> Date {
        let time = JournalDates.calendar.dateComponents([.hour, .minute], from: date)
        return JournalDates.calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }

    static func time(_ date: Date, hour: Int? = nil, minute: Int? = nil, pm: Bool? = nil) -> Date {
        let calendar = JournalDates.calendar
        let currentHour = calendar.component(.hour, from: date)
        let hour24 = (hour.map { $0 % 12 } ?? (currentHour % 12)) + ((pm ?? (currentHour >= 12)) ? 12 : 0)
        return calendar.date(bySettingHour: hour24, minute: minute ?? calendar.component(.minute, from: date), second: 0, of: date) ?? date
    }

    /// 从钟面位置得到 1…12 小时或 0…59 分钟；12 点在正上方。
    static func dialValue(at point: CGPoint, size: CGFloat, minutes: Bool) -> Int {
        let angle = atan2(point.x - size / 2, size / 2 - point.y)
        let fraction = (angle / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
        let value = Int((fraction * (minutes ? 60 : 12)).rounded()) % (minutes ? 60 : 12)
        return minutes ? value : (value == 0 ? 12 : value)
    }

    static func endpoint(date: Date, minutes: Bool) -> CGPoint {
        let calendar = JournalDates.calendar
        let minute = Double(calendar.component(.minute, from: date))
        let value = minutes ? minute / 60 : (Double(calendar.component(.hour, from: date) % 12) + minute / 60) / 12
        let angle = value * 2 * .pi
        let length: CGFloat = minutes ? 57 : 36
        return CGPoint(x: 83 + sin(angle) * length, y: 83 - cos(angle) * length)
    }

    /// 点中指针或其末端时直接选它；重叠时以更近的末端决定。
    static func hand(at point: CGPoint, date: Date) -> Bool? {
        func distance(minutes: Bool) -> CGFloat {
            let end = endpoint(date: date, minutes: minutes)
            let vx = end.x - 83, vy = end.y - 83
            let t = min(1, max(0.3, ((point.x - 83) * vx + (point.y - 83) * vy) / (vx * vx + vy * vy)))
            return hypot(point.x - 83 - t * vx, point.y - 83 - t * vy)
        }
        let hour = distance(minutes: false), minute = distance(minutes: true)
        guard min(hour, minute) <= 10 else { return nil }
        return minute < hour
    }
}

struct DeadlineSelectionView: View {
    @Binding var due: Date
    @Binding var timed: Bool
    @Environment(\.locale) private var locale
    @AppStorage(Prefs.weekStartsSunday) private var sundayFirst = false
    @State private var month: Date

    init(due: Binding<Date>, timed: Binding<Bool>) {
        _due = due; _timed = timed
        _month = State(initialValue: JournalDates.monthStart(due.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach([("今天", 0), ("明天", 1), ("下周一", -1)], id: \.0) { title, offset in
                    Button(LocalizedStringKey(title)) {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        let today = JournalDates.calendar.startOfDay(for: Date())
                        let weekday = (JournalDates.calendar.component(.weekday, from: today) + 5) % 7
                        let day = JournalDates.calendar.date(byAdding: .day, value: offset < 0 ? 7 - weekday : offset, to: today) ?? today
                        due = DeadlineSelection.day(day, keepingTime: due)
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            calendar
            HStack {
                Text("截止日期").font(.system(size: 12))
                Spacer()
                DeadlineTextInput(due: $due, component: .day).frame(width: 118, height: 26)
            }
            Divider()
            HStack {
                Toggle("指定时间", isOn: $timed).toggleStyle(.checkbox).font(.system(size: 12))
                Spacer()
                Text(timed ? "24 小时制" : "全天").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                if timed {
                    HStack(spacing: 7) {
                        Image(systemName: "clock").foregroundStyle(Palette.accent)
                        DeadlineTextInput(due: $due, component: .hour24).frame(width: 44, height: 28)
                        Text(":").foregroundStyle(Palette.muted)
                        DeadlineTextInput(due: $due, component: .minute).frame(width: 44, height: 28)
                        Spacer()
                        Text("HH:mm").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                    }
                    HStack(spacing: 6) {
                        ForEach([9, 12, 18], id: \.self) { hour in
                            Button(String(format: "%02d:00", hour)) {
                                NSApp.keyWindow?.makeFirstResponder(nil)
                                due = JournalDates.calendar.date(bySettingHour: hour, minute: 0, second: 0, of: due) ?? due
                            }.buttonStyle(.bordered).controlSize(.mini)
                        }
                    }
                } else {
                    Text("全天任务，在当天结束时截止").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }.frame(height: 62, alignment: .top)
        }
        .frame(width: 280)
        .onChange(of: due) { value in month = JournalDates.monthStart(value) }
        .foregroundStyle(Palette.ink).tint(Palette.accent)
    }

    private var weekdays: [String] {
        let symbols = DateFormatters.formatter(locale: locale).shortStandaloneWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let start = sundayFirst ? 0 : 1
        return (0..<7).map { symbols[($0 + start) % 7] }
    }

    private var calendar: some View {
        VStack(spacing: 5) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                    .accessibilityLabel("上个月")
                Spacer(minLength: 0)
                Text(month, format: .dateTime.year().month(.wide)).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }
                    .accessibilityLabel("下个月")
            }
            HStack(spacing: 0) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.system(size: 10)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(JournalDates.monthGrid(month, weekStart: sundayFirst ? 1 : 2), id: \.self) { day in
                    let selected = JournalDates.calendar.isDate(day, inSameDayAs: due)
                    let inMonth = JournalDates.calendar.isDate(day, equalTo: month, toGranularity: .month)
                    Button {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        due = DeadlineSelection.day(day, keepingTime: due)
                    } label: {
                        Text("\(JournalDates.calendar.component(.day, from: day))")
                            .font(.system(size: 12, weight: selected ? .semibold : .regular)).monospacedDigit()
                            .foregroundStyle(selected ? Color.white : Palette.ink.opacity(inMonth ? 1 : 0.35))
                            .frame(maxWidth: .infinity).frame(height: 28)
                            .background(selected ? Palette.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(JournalDates.calendar.isDateInToday(day) && !selected ? Palette.accent : .clear))
                    }
                    .raisedOnHover(radius: 6)
                    .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .frame(height: 178, alignment: .top)
        }
        .buttonStyle(.plain)
    }

    private func shiftMonth(_ delta: Int) {
        month = JournalDates.calendar.date(byAdding: .month, value: delta, to: month) ?? month
    }
}

struct DeadlineClockPicker: View {
    @Binding var due: Date
    @State private var minutes = false
    @State private var draggedMinutes: Bool?
    private var hour: Int { JournalDates.calendar.component(.hour, from: due) }
    private var minute: Int { JournalDates.calendar.component(.minute, from: due) }
    private var pm: Binding<Bool> {
        Binding(get: { hour >= 12 }, set: { due = DeadlineSelection.time(due, pm: $0) })
    }

    var body: some View {
        VStack(spacing: 8) {
            segments(first: "时针", second: "分针", selection: $minutes)
            dial
            HStack(spacing: 3) {
                DeadlineTextInput(due: $due, component: .hour).frame(width: 42, height: 24)
                Text(":").foregroundStyle(Palette.muted)
                DeadlineTextInput(due: $due, component: .minute).frame(width: 42, height: 24)
            }
            segments(first: "AM", second: "PM", selection: pm)
        }
    }

    private func segments(first: String, second: String, selection: Binding<Bool>) -> some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { value in
                Button {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    selection.wrappedValue = value
                } label: {
                    Text(LocalizedStringKey(value ? second : first))
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .foregroundStyle(selection.wrappedValue == value ? Palette.accent : Palette.muted)
                        .background(selection.wrappedValue == value ? Palette.soft : .clear, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).raisedOnHover(radius: 5)
                    .accessibilityAddTraits(selection.wrappedValue == value ? .isSelected : [])
            }
        }.padding(2).background(Palette.background, in: RoundedRectangle(cornerRadius: 7))
    }

    private var dial: some View {
        let size: CGFloat = 166
        let radius: CGFloat = 64
        return ZStack {
            Circle().fill(Palette.background)
                .overlay(Circle().strokeBorder(Palette.line, lineWidth: 0.75))
            ForEach(0..<60) { index in
                let angle = Double(index) * .pi / 30
                Path { path in
                    let outer: CGFloat = 79
                    let inner: CGFloat = index.isMultiple(of: 5) ? 74 : 77
                    path.move(to: CGPoint(x: 83 + sin(angle) * inner, y: 83 - cos(angle) * inner))
                    path.addLine(to: CGPoint(x: 83 + sin(angle) * outer, y: 83 - cos(angle) * outer))
                }.stroke(Palette.muted.opacity(0.45), lineWidth: 0.75)
            }
            ForEach(0..<12) { index in
                let angle = Double(index) * .pi / 6
                Text("\(index == 0 ? 12 : index)")
                    .font(.system(size: 12)).monospacedDigit()
                    .position(x: 83 + sin(angle) * radius, y: 83 - cos(angle) * radius)
            }
            hand(minutes: false)
            hand(minutes: true)
            Circle().fill(Palette.accent).frame(width: 6, height: 6)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { event in
            if draggedMinutes == nil {
                NSApp.keyWindow?.makeFirstResponder(nil)
                draggedMinutes = DeadlineSelection.hand(at: event.startLocation, date: due) ?? minutes
                minutes = draggedMinutes ?? minutes
            }
            if hypot(event.translation.width, event.translation.height) > 3 {
                setTime(at: event.location, minutes: draggedMinutes ?? minutes)
            }
        }.onEnded { event in
            let moved = hypot(event.translation.width, event.translation.height) > 3
            if moved || DeadlineSelection.hand(at: event.startLocation, date: due) == nil {
                setTime(at: event.location, minutes: draggedMinutes ?? minutes)
            }
            draggedMinutes = nil
        })
        .accessibilityElement(children: .contain).accessibilityLabel("钟表选择时间")
    }

    private func hand(minutes isMinute: Bool) -> some View {
        let endpoint = DeadlineSelection.endpoint(date: due, minutes: isMinute)
        let active = minutes == isMinute
        let color = active ? Palette.accent : Palette.muted
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 83, y: 83))
                path.addLine(to: endpoint)
            }.stroke(color, style: StrokeStyle(lineWidth: isMinute ? 2 : 4, lineCap: .round))
            Circle().fill(Palette.card).overlay(Circle().strokeBorder(color, lineWidth: 2))
                .frame(width: active ? 11 : 8, height: active ? 11 : 8)
                .position(endpoint)
        }.allowsHitTesting(false)
    }

    private func setTime(at point: CGPoint, minutes: Bool) {
        let picked = DeadlineSelection.dialValue(at: point, size: 166, minutes: minutes)
        due = minutes ? DeadlineSelection.time(due, minute: picked) : DeadlineSelection.time(due, hour: picked)
    }
}

/// 普通文本框不带系统日历弹窗。时、分分别输入，编辑回调始终保留当前 AM/PM。
struct DeadlineTextInput: NSViewRepresentable {
    enum Component { case day, hour, hour24, minute }
    @Binding var due: Date
    let component: Component

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.alignment = component == .day ? .left : .center
        field.setAccessibilityLabel(AppLocalized(component == .day ? "截止日期" : (component == .minute ? "分钟" : "小时")))
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil { field.stringValue = display }
    }

    var display: String {
        let calendar = JournalDates.calendar
        switch component {
        case .day: return JournalDates.key(due)
        case .hour:
            let hour = calendar.component(.hour, from: due) % 12
            return String(format: "%02d", hour == 0 ? 12 : hour)
        case .hour24: return String(format: "%02d", calendar.component(.hour, from: due))
        case .minute: return String(format: "%02d", calendar.component(.minute, from: due))
        }
    }

    func apply(_ text: String) {
        switch component {
        case .day:
            if let day = JournalDates.date(for: text) { due = DeadlineSelection.day(day, keepingTime: due) }
        case .hour:
            if let hour = Int(text), (1...12).contains(hour) { due = DeadlineSelection.time(due, hour: hour) }
        case .hour24:
            if let hour = Int(text), (0...23).contains(hour),
               let updated = JournalDates.calendar.date(bySettingHour: hour, minute: JournalDates.calendar.component(.minute, from: due), second: 0, of: due) {
                due = updated
            }
        case .minute:
            if let minute = Int(text), (0...59).contains(minute) { due = DeadlineSelection.time(due, minute: minute) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DeadlineTextInput
        init(_ parent: DeadlineTextInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.apply(field.stringValue)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // 有效输入已在变更时写入；失焦只规范显示，避免旧文字覆盖刚点选的日期或 AM/PM。
            field.stringValue = parent.display
        }
    }
}
