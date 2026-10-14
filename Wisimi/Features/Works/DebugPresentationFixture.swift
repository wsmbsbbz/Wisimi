#if DEBUG
import SwiftUI

/// Exercises the real controls without login or remote mutations.
struct DebugWorkActionsPreview: View {
    @State private var isMarkMenuPresented = false
    @State private var isPlaylistMenuPresented = false
    @State private var isLoading = false
    @State private var markCount = 0
    @State private var loginCount = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ChipFlowLayout(spacing: 6) {
                        MetricPill(text: "4.8", systemImage: "star.fill")
                        MetricPill(text: "30m", systemImage: "clock")
                        VoiceActorChip(text: "声优")
                        CircleChip(text: "社团")
                        TagChip(text: "作品标签")
                    }
                    ReviewActionButton(
                        isMarked: false, currentStatus: nil, isLoading: isLoading,
                        isMenuPresented: $isMarkMenuPresented, message: nil,
                        action: { markCount += 1; isMarkMenuPresented = true },
                        onStatusSelected: { _ in }
                    )
                    PlaylistActionButton(
                        workID: 0, client: ASMRClient(), token: nil,
                        isMenuPresented: $isPlaylistMenuPresented,
                        onLoginRequired: { loginCount += 1 }
                    )
                    Toggle("模拟标记加载中", isOn: $isLoading)
                    Text("标记点击：\(markCount)；播放列表点击：\(loginCount)")
                        .font(.caption)
                }
                .padding(16)
            }
            .navigationTitle("操作区域验收")
        }
    }
}
#endif
