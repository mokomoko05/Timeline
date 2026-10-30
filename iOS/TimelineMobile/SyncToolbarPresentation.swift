import Combine
import SwiftUI
import TimelineCore
import UIKit

/// 只发布工具栏结构变化，图标的状态由按钮单独订阅。键盘弹出时指示器保持安静。
@MainActor
final class SyncToolbarPresentation: ObservableObject {
    let indicator: SyncIndicator
    @Published private(set) var visible: Bool
    private var observations: [AnyCancellable] = []

    init(sync: FolderSync) {
        indicator = SyncIndicator(sync: sync)
        visible = indicator.state != .hidden
        observations.append(indicator.$state.map { $0 != .hidden }.removeDuplicates().sink { [weak self] value in
            guard let self, self.visible != value else { return }
            withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) {
                self.visible = value
            }
        })
        let center = NotificationCenter.default
        observations.append(center.publisher(for: UIResponder.keyboardWillShowNotification).sink { [weak self] _ in self?.indicator.setEditing(true) })
        observations.append(center.publisher(for: UIResponder.keyboardWillHideNotification).sink { [weak self] _ in self?.indicator.setEditing(false) })
    }
}
