import SwiftUI
import DayleafCore

/// 日期、钟表与文本输入共享同一份值，切换日期时保留已选时间。
enum DeadlineSelection {
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
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                calendar
                DatePicker("截止日期", selection: Binding(get: { due }, set: { due = DeadlineSelection.day($0, keepingTime: due) }), displayedComponents: .date)
                    .datePickerStyle(.field).font(.system(size: 12))
                Toggle("指定时间", isOn: $timed).toggleStyle(.checkbox).font(.system(size: 12))
            }.frame(width: 224)
            if timed {
                DeadlineClockPicker(due: $due)
                    .frame(width: 170)
            }
        }
        .onChange(of: due) { value in month = JournalDates.monthStart(value) }
        .foregroundStyle(Palette.ink).tint(Palette.accent)
    }

    private var weekdays: [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        let symbols = formatter.shortStandaloneWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
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
                    Button { due = DeadlineSelection.day(day, keepingTime: due) } label: {
                        Text("\(JournalDates.calendar.component(.day, from: day))")
                            .font(.system(size: 12, weight: selected ? .semibold : .regular)).monospacedDigit()
                            .foregroundStyle(selected ? Color.white : Palette.ink.opacity(inMonth ? 1 : 0.35))
                            .frame(maxWidth: .infinity).frame(height: 26)
                            .background(selected ? Palette.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(JournalDates.calendar.isDateInToday(day) && !selected ? Palette.accent : .clear))
                    }
                    .raisedOnHover(radius: 6)
                    .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .frame(height: 166, alignment: .top)
        }
        .buttonStyle(.plain)
    }

    private func shiftMonth(_ delta: Int) {
        month = JournalDates.calendar.date(byAdding: .month, value: delta, to: month) ?? month
    }
}

private struct DeadlineClockPicker: View {
    @Binding var due: Date
    @State private var minutes = false
    private var hour: Int { JournalDates.calendar.component(.hour, from: due) }
    private var minute: Int { JournalDates.calendar.component(.minute, from: due) }
    private var pm: Binding<Bool> {
        Binding(get: { hour >= 12 }, set: { due = DeadlineSelection.time(due, pm: $0) })
    }

    var body: some View {
        VStack(spacing: 8) {
            segments(first: "小时", second: "分钟", selection: $minutes)
            dial
            DatePicker("截止时间", selection: $due, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field).labelsHidden()
                .environment(\.locale, Locale(identifier: "en_US"))
                .accessibilityLabel("手动输入时间")
            segments(first: "AM", second: "PM", selection: pm)
        }
    }

    private func segments(first: String, second: String, selection: Binding<Bool>) -> some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { value in
                Button { selection.wrappedValue = value } label: {
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
        let value = minutes ? Double(minute) / 60 : Double(hour % 12) / 12
        let angle = value * 2 * .pi
        return ZStack {
            Circle().fill(Palette.background)
                .overlay(Circle().strokeBorder(Palette.line, lineWidth: 0.75))
            Path { path in
                path.move(to: CGPoint(x: size / 2, y: size / 2))
                path.addLine(to: CGPoint(x: size / 2 + sin(angle) * (radius - 15), y: size / 2 - cos(angle) * (radius - 15)))
            }.stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            Circle().fill(Palette.accent).frame(width: 5, height: 5)
            ForEach(0..<12) { index in
                let tickAngle = Double(index) * .pi / 6
                let number = minutes ? index * 5 : (index == 0 ? 12 : index)
                let selected = minutes ? minute == number : hour % 12 == index
                Button {
                    if minutes { due = DeadlineSelection.time(due, minute: number) }
                    else { due = DeadlineSelection.time(due, hour: number); minutes = true }
                } label: {
                    Text(minutes ? String(format: "%02d", number) : "\(number)")
                        .font(.system(size: 12, weight: selected ? .semibold : .regular)).monospacedDigit()
                        .frame(width: 27, height: 27)
                        .foregroundStyle(selected ? Color.white : Palette.ink)
                        .background(selected ? Palette.accent : .clear, in: Circle())
                }.buttonStyle(.plain)
                    .position(x: size / 2 + sin(tickAngle) * radius, y: size / 2 - cos(tickAngle) * radius)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { event in
            let picked = DeadlineSelection.dialValue(at: event.location, size: size, minutes: minutes)
            if minutes { due = DeadlineSelection.time(due, minute: picked) }
            else { due = DeadlineSelection.time(due, hour: picked) }
        })
        .accessibilityElement(children: .contain).accessibilityLabel("钟表选择时间")
    }
}
