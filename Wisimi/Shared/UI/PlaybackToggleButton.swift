import SwiftUI

struct PlaybackToggleButton: View {
    let state: PlaybackState
    var isCompact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(isCompact ? .body : .system(size: 64))
                .contentTransition(.identity)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .accessibilityLabel(state.wantsPlayback ? "暂停" : "播放")
        .accessibilityValue(state == .preparing ? "正在准备播放" : "")
    }

    private var symbol: String {
        let action = state.wantsPlayback ? "pause" : "play"
        return isCompact ? "\(action).fill" : "\(action).circle.fill"
    }
}

struct PressFeedbackButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
    }
}
