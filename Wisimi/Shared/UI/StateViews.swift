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

struct InlineRetryView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试", action: retry)
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: .rect(cornerRadius: 12))
    }
}
