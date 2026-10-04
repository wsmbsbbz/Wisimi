import SwiftUI

struct DownloadsView: View {
    @State private var downloads = DownloadStore.shared
    @State private var deletion: Set<UUID> = []
    @State private var isDeletePresented = false
    let openWork: (Int) -> Void

    var body: some View {
        List {
            Section {
                LabeledContent("已缓存", value: ByteCountFormatter.string(fromByteCount: downloads.cachedBytes, countStyle: .file))
                Text("下载保存在本机，音视频、字幕和图片优先使用本地文件。后台下载由系统调度。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = downloads.message {
                Section {
                    Text(message).foregroundStyle(.red)
                    Button("关闭提示") { downloads.message = nil }
                }
            }
            if !downloads.isReady && downloads.message == nil {
                ProgressView("恢复下载任务…")
            } else if downloads.entries.isEmpty {
                ContentUnavailableView("暂无下载", systemImage: "arrow.down.circle", description: Text("在作品详情的文件目录中选择文件，然后点击下载。"))
            }
            ForEach(downloads.works.sorted { $0.id > $1.id }) { saved in
                Section {
                    Button {
                        openWork(saved.id)
                    } label: {
                        Label("打开作品与文件目录", systemImage: "folder")
                    }
                    ForEach(downloads.entries.filter { $0.workID == saved.id }) { entry in
                        DownloadTaskRow(entry: entry, downloads: downloads) {
                            deletion = [entry.id]
                            isDeletePresented = true
                        }
                    }
                } header: {
                    Text("RJ\(String(saved.id)) · \(saved.work.title)")
                }
            }
        }
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("暂停全部") {
                        for entry in downloads.entries where entry.state == .downloading { downloads.pause(entry.id) }
                    }
                    Button("继续全部") {
                        for entry in downloads.entries where entry.state == .paused { downloads.resume(entry.id) }
                    }
                    Button("重试失败项") {
                        for entry in downloads.entries where entry.state == .failed { downloads.retry(entry.id) }
                    }
                    Button("删除全部", role: .destructive) {
                        deletion = Set(downloads.entries.map(\.id))
                        isDeletePresented = true
                    }
                } label: {
                    Label("管理下载", systemImage: "ellipsis.circle")
                }
                .disabled(downloads.entries.isEmpty || !downloads.isReady)
            }
        }
        .confirmationDialog("删除所选下载？", isPresented: $isDeletePresented, titleVisibility: .visible) {
            Button("删除 \(deletion.count) 个文件", role: .destructive) { downloads.remove(deletion) }
        } message: {
            Text("正在下载的任务会取消，已缓存的本地文件会删除。之后可重新下载。")
        }
    }
}

private struct DownloadTaskRow: View {
    let entry: DownloadEntry
    let downloads: DownloadStore
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.track.title)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(entry.state.title, systemImage: entry.state.symbol)
                    .foregroundStyle(entry.state == .completed ? Color.green : Color.secondary)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: entry.received, countStyle: .file))
                    .monospacedDigit()
                if entry.expected > 0 && entry.state != .completed {
                    Text("/ " + ByteCountFormatter.string(fromByteCount: entry.expected, countStyle: .file))
                }
            }
            .font(.caption)
            if entry.state == .downloading {
                if let progress = entry.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = entry.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if entry.state == .downloading {
                    Button("暂停", systemImage: "pause") { downloads.pause(entry.id) }
                } else if entry.state == .paused {
                    Button("继续", systemImage: "play") { downloads.resume(entry.id) }
                } else if entry.state == .failed {
                    Button("重试", systemImage: "arrow.clockwise") { downloads.retry(entry.id) }
                }
                Spacer()
                Button("删除", systemImage: "trash", role: .destructive, action: delete)
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            .disabled(!downloads.isReady)
        }
        .padding(.vertical, 4)
    }
}
