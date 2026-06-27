import SwiftUI

struct RetryView: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("加载失败", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("重试") {
                Task { await retry() }
            }
        }
    }
}

struct EmptyStateView: View {
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("暂无内容", systemImage: "tray")
        } actions: {
            Button("重试") {
                Task { await retry() }
            }
        }
    }
}
