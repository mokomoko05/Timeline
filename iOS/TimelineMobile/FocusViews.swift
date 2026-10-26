import SwiftUI
import TimelineCore

/// 开始专注：选时长、写一句这轮要做成什么（可不写）。
struct FocusStartSheet: View {
    @ObservedObject var store: JournalStore
    @EnvironmentObject private var focus: FocusTimer
    let taskID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = UserDefaults.standard.object(forKey: FocusTimer.minutesKey) as? Int ?? 25
    @State private var goal = ""

    var body: some View {
        NavigationStack {
            Form {
                if let item = store.locate(taskID) {
                    Section {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let number = item.task.number { Text("#\(number)").foregroundStyle(Palette.accent).monospacedDigit() }
                            Text(TaskText.rendered(item.task.title)).font(.body.weight(.medium))
                        }
                    }
                }
                Section("时长") {
                    Picker("时长", selection: $minutes) {
                        ForEach(Array(Set(FocusTimer.durations + [minutes])).sorted(), id: \.self) { Text(LF("%lld 分钟", $0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper(LF("%lld 分钟", minutes), value: $minutes, in: 5...240, step: 5)
                }
                Section {
                    TextField("这一轮要做成什么？（可不写）", text: $goal, axis: .vertical)
                } footer: {
                    Text("不到 5 分钟又没写目标的一轮不留日志，时长照样累加到任务上。")
                }
                if focus.isActive {
                    Section { Text("会先结束正在进行的专注。").foregroundStyle(Palette.muted) }
                }
            }
            .navigationTitle("开始专注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始") {
                        if let item = store.locate(taskID) { focus.start(task: item, minutes: minutes, goal: goal) }
                        dismiss()
                    }
                    .disabled(store.locate(taskID) == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 专注进行中时贴在页面底部的一条：任务名、剩余时间、暂停 / 继续；点开是完整的计时页。
struct FocusBar: View {
    @EnvironmentObject private var focus: FocusTimer
    @State private var expanded = false

    var body: some View {
        if let session = focus.session {
            HStack(spacing: 12) {
                FocusRing(session: session, lineWidth: 3)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text((session.number.map { "#\($0) " } ?? "") + session.title)
                        .font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(statusKey(session)).font(.caption).foregroundStyle(session.finished ? Palette.deadline : Palette.muted)
                }
                Spacer(minLength: 4)
                FocusClock(font: .body.weight(.semibold).monospacedDigit())
                Button { focus.togglePause() } label: {
                    Image(systemName: focus.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 34, height: 34)
                        .background(Palette.accent.opacity(0.12), in: Circle())
                }
                .disabled(session.finished)
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
            }
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.line.opacity(0.5)))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { expanded = true }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .sheet(isPresented: $expanded) { FocusSheet() }
            .sensoryFeedback(.success, trigger: session.finished) { _, new in new }
        }
    }

    private func statusKey(_ session: FocusTimer.Session) -> LocalizedStringKey {
        session.finished ? "时间到 · 点开选择结束或加时" : (session.pausedAt != nil ? "已暂停" : "专注中")
    }
}

/// 剩余时间，每秒刷新（只有这一小块跟着刷新）。
struct FocusClock: View {
    @EnvironmentObject private var focus: FocusTimer
    var font: Font

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(FocusTimer.clock(focus.remaining(at: context.date)))
                .font(font)
                .foregroundStyle(focus.session?.finished == true ? Palette.deadline : Palette.ink)
                .contentTransition(.numericText(countsDown: true))
        }
    }
}

/// 剩余时间的圆环。
struct FocusRing: View {
    @EnvironmentObject private var focus: FocusTimer
    let session: FocusTimer.Session
    var lineWidth: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = focus.remaining(at: context.date) / max(1, session.plannedSeconds)
            ZStack {
                Circle().stroke(Palette.line.opacity(0.6), lineWidth: lineWidth)
                Circle().trim(from: 0, to: left)
                    .stroke(session.finished ? Palette.deadline : Palette.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: left)
            }
        }
    }
}

/// 完整的计时页：大圆环、暂停 / 继续、加时、结束、记一笔。
struct FocusSheet: View {
    @EnvironmentObject private var focus: FocusTimer
    @Environment(\.dismiss) private var dismiss
    @State private var composing = false
    @State private var confirmingStop = false

    var body: some View {
        NavigationStack {
            if let session = focus.session {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        Text((session.number.map { "#\($0) " } ?? "") + session.title)
                            .font(.title3.weight(.semibold)).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                        if !session.goal.isEmpty {
                            Label(session.goal, systemImage: "flag").font(.subheadline).foregroundStyle(Palette.muted)
                        }
                    }
                    ZStack {
                        FocusRing(session: session, lineWidth: 10)
                        VStack(spacing: 4) {
                            FocusClock(font: .system(size: 54, weight: .semibold).monospacedDigit())
                            Text(session.finished ? "时间到" : (session.pausedAt != nil ? "已暂停" : "专注中"))
                                .font(.subheadline).foregroundStyle(session.finished ? Palette.deadline : Palette.muted)
                        }
                    }
                    .frame(width: 250, height: 250)
                    HStack(spacing: 14) {
                        if session.finished {
                            Button { focus.extend(minutes: 5) } label: { Label("再 5 分钟", systemImage: "plus") }
                                .buttonStyle(.bordered)
                        } else {
                            Button { focus.togglePause() } label: {
                                Label(session.pausedAt != nil ? "继续" : "暂停", systemImage: session.pausedAt != nil ? "play.fill" : "pause.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            Button { focus.extend(minutes: 5) } label: { Label("+5 分钟", systemImage: "plus") }
                                .buttonStyle(.bordered)
                        }
                    }
                    .controlSize(.large)
                    HStack(spacing: 14) {
                        Button { composing = true } label: { Label("记一笔", systemImage: "square.and.pencil") }
                            .buttonStyle(.bordered)
                        Button(role: .destructive) {
                            if session.finished { finish("计时结束") } else { confirmingStop = true }
                        } label: { Label("结束", systemImage: "stop.fill") }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                }
                .padding(.top, 24)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .background(Palette.background)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("收起") { dismiss() } } }
                .confirmationDialog("提前结束这一轮专注？", isPresented: $confirmingStop, titleVisibility: .visible) {
                    Button("结束专注", role: .destructive) { finish("手动结束") }
                }
                .sheet(isPresented: $composing) { ComposeSheet(store: focus.store, taskID: session.taskID) }
            } else {
                ContentUnavailableView("没有进行中的专注", systemImage: "timer")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            }
        }
    }

    private func finish(_ reason: String) {
        focus.stop(reason: reason)
        dismiss()
    }
}
