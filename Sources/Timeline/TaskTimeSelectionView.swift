import SwiftUI
import TimelineCore

struct TaskTimeSelectionView: View {
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
                ForEach(TaskTimeMode.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if timing.mode == .interval {
                HStack(spacing: 8) {
                    ForEach(TaskTimeEndpoint.allCases) { item in
                        Button {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            endpoint = item
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizedStringKey(item.title)).font(.system(size: 11))
                                Text(timing.date(for: item), format: .dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                .background(endpoint == item ? Palette.accent.opacity(0.12) : Palette.soft, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(endpoint == item ? Palette.accent.opacity(0.6) : Palette.line, lineWidth: 1))
                        }.buttonStyle(.plain).foregroundStyle(endpoint == item ? Palette.accent : Palette.muted)
                            .accessibilityIdentifier("task-time-endpoint-" + item.rawValue)
                            .accessibilityAddTraits(endpoint == item ? .isSelected : [])
                    }
                }
            }
            DeadlineSelectionView(due: selectedDate, timed: .constant(timing.hasTime), showsTimeToggle: false,
                                  dateTitle: timing.mode == .interval ? endpoint.title : "截止日期")
            if !timing.isValid {
                Text("结束时间必须晚于开始时间").font(.caption).foregroundStyle(Palette.danger)
            }
        }.frame(width: 280)
    }
}
