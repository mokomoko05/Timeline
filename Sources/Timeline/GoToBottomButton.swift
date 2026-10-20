import SwiftUI

struct GoToBottomButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("跳到最新", systemImage: "arrow.down.to.line")
                .font(.system(size: 11))
        }
        .buttonStyle(HitAreaButtonStyle(compact: true))
        .help("跳到最新日志")
        .accessibilityIdentifier("journal-go-to-bottom")
    }
}
