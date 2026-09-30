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
        .buttonStyle(PlaybackPressStyle())
        .accessibilityLabel(state.wantsPlayback ? "暂停" : "播放")
        .accessibilityValue(state == .preparing ? "正在准备播放" : "")
    }

    private var symbol: String {
        let action = state.wantsPlayback ? "pause" : "play"
        return isCompact ? "\(action).fill" : "\(action).circle.fill"
    }
}

private struct PlaybackPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}
