import SwiftUI
import TimelineCore

struct TaskTimeFields: View {
    @Binding var timing: TaskTimeDraft
    @State private var endpoint: TaskTimeEndpoint = .start

    private var selectedDate: Binding<Date> {
        Binding(get: { timing.mode == .interval ? timing.date(for: endpoint) : timing.end }, set: {
            if timing.mode == .interval { timing.setDate($0, for: endpoint) } else { timing.end = $0 }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("任务时间", selection: $timing.mode) {
                ForEach(TaskTimeMode.allCases) { Text(L($0.title)).tag($0) }
            }.pickerStyle(.segmented)
            if timing.mode == .interval {
                HStack(spacing: 8) {
                    ForEach(TaskTimeEndpoint.allCases) { item in
                        Button { endpoint = item } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L(item.title)).font(.caption)
                                Text(timing.date(for: item), format: .dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                                    .font(.subheadline.weight(.medium)).monospacedDigit().lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(endpoint == item ? Palette.accent.opacity(0.12) : Palette.background, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(endpoint == item ? Palette.accent.opacity(0.6) : Palette.line, lineWidth: 1))
                        }.buttonStyle(.plain).foregroundStyle(endpoint == item ? Palette.accent : Palette.muted)
                            .accessibilityIdentifier("task-time-endpoint-" + item.rawValue)
                            .accessibilityAddTraits(endpoint == item ? .isSelected : [])
                    }
                }
            }
            DatePicker("日期", selection: selectedDate, displayedComponents: .date)
            if timing.hasTime { DatePicker("时间", selection: selectedDate, displayedComponents: .hourAndMinute) }
            if !timing.isValid {
                Text("结束时间必须晚于开始时间").font(.caption).foregroundStyle(Palette.danger)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PerfProbe.action)) { note in
            if note.object as? String == "taskIntervalSelectStart" { endpoint = .start }
            if note.object as? String == "taskIntervalSelectEnd" { endpoint = .end }
        }
    }
}
