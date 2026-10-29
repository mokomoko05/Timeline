import SwiftUI
import TimelineCore

struct TaskTimeFields: View {
    @Binding var timing: TaskTimeDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("任务时间", selection: $timing.mode) {
                ForEach(TaskTimeMode.allCases) { Text(L($0.title)).tag($0) }
            }.pickerStyle(.segmented)
            if timing.mode == .interval {
                DatePicker("开始时间", selection: $timing.start, displayedComponents: [.date, .hourAndMinute])
                DatePicker("结束时间", selection: $timing.end, displayedComponents: [.date, .hourAndMinute])
                Text("按开始时间排列，结束后视为逾期；提醒以开始时间为准。")
                    .font(.caption).foregroundStyle(Palette.muted)
                if !timing.isValid {
                    Text("结束时间必须晚于开始时间").font(.caption).foregroundStyle(Palette.danger)
                }
            } else {
                DatePicker("日期", selection: $timing.end, displayedComponents: .date)
                if timing.hasTime { DatePicker("截止时刻", selection: $timing.end, displayedComponents: .hourAndMinute) }
            }
        }
    }
}
