import Combine
import SwiftUI
import TimelineCore
import UIKit

/// 只发布工具栏结构变化，阶段动画由按钮单独订阅。
@MainActor
final class SyncToolbarPresentation: ObservableObject {
    let feedback: SyncButtonFeedback
    @Published private(set) var visible: Bool
    private var observation: AnyCancellable?

    init(sync: FolderSync) {
        feedback = SyncButtonFeedback(sync: sync)
        visible = feedback.shouldShow
        observation = feedback.$shouldShow.removeDuplicates().sink { [weak self] value in
            guard let self, self.visible != value else { return }
            withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.24)) {
                self.visible = value
            }
        }
    }
}
