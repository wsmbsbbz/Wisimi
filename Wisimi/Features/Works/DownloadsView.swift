import SwiftUI

struct DownloadsView: View {
    @State private var downloads = DownloadStore.shared
    @State private var filter: DownloadFilter = .all
    @State private var expanded: Set<Int> = []
    @State private var deletion: Set<UUID> = []
    @State private var isDeletePresented = false
    @State private var isInfoPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let openWork: (Int) -> Void

    var body: some View {
        let groups = DownloadWorkGroup.make(works: downloads.works, entries: downloads.entries, filter: filter)
        List {
            Section {
                DownloadStorageSummary(bytes: downloads.cachedBytes, summary: DownloadSummary(entries: downloads.entries))
                filterControl.listRowSeparator(.hidden)
            }
            if let message = downloads.message {
                Section {
                    Text(message).foregroundStyle(.red)
                    Button("关闭提示") { downloads.message = nil }
                        .frame(minHeight: 44)
                }
            }
            if !downloads.isReady && downloads.message == nil {
                ProgressView("恢复下载任务…")
            } else if groups.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(filter == .all ? "暂无下载" : "暂无\(filter.rawValue)文件", systemImage: "arrow.down.circle")
                    } description: {
                        Text(filter == .all ? "在作品详情的文件目录中选择文件，然后点击下载。" : "试试查看全部下载。")
                    } actions: {
                        if filter != .all { Button("查看全部") { filter = .all }.frame(minHeight: 44) }
                    }
                }
            }
            ForEach(groups) { group in
                Section {
                    DownloadWorkHeader(group: group, isExpanded: expanded.contains(group.id), openWork: { openWork(group.id) }, toggle: {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
                            if !expanded.insert(group.id).inserted { expanded.remove(group.id) }
                        }
                    }) {
                        DownloadManagementActions(entries: group.entries, downloads: downloads, scope: "本作品全部所选文件", delete: requestDeletion)
                    }
                    if expanded.contains(group.id) {
                        ForEach(group.visibleEntries) { entry in
                            DownloadTaskRow(entry: entry, downloads: downloads) { requestDeletion([entry.id]) }
                                .swipeActions(allowsFullSwipe: false) {
                                    Button("删除", role: .destructive) { requestDeletion([entry.id]) }
                                        .disabled(!downloads.isReady)
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("下载与存储说明", systemImage: "info.circle") { isInfoPresented = true }
                    if !downloads.entries.isEmpty {
                        DownloadManagementActions(entries: downloads.entries, downloads: downloads, scope: "全部下载文件", delete: requestDeletion)
                    }
                } label: {
                    Label("管理下载", systemImage: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["WISIMI_DEBUG_DOWNLOAD_EXPANDED"] == "1" {
                expanded = Set(downloads.works.map(\.id))
            }
            #endif
        }
        .onChange(of: downloads.works.count) {
            #if DEBUG
            if ProcessInfo.processInfo.environment["WISIMI_DEBUG_DOWNLOAD_EXPANDED"] == "1" {
                expanded = Set(downloads.works.map(\.id))
            }
            #endif
        }
        .alert("下载与存储", isPresented: $isInfoPresented) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("下载保存在本机，音视频、字幕和图片优先使用本地文件。后台下载由系统调度。占用统计仅包含已完成文件，下载中的任务还可能占用系统临时空间。")
        }
        .alert("删除 \(deletion.count) 个下载文件？", isPresented: $isDeletePresented) {
            Button("删除 \(deletion.count) 个文件", role: .destructive) { downloads.remove(deletion) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("所选任务会取消，已下载的本地文件会删除。之后可重新下载。")
        }
    }

    @ViewBuilder private var filterControl: some View {
        if typeSize.isAccessibilitySize {
            Menu {
                Picker("显示下载", selection: $filter) {
                    ForEach(DownloadFilter.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                HStack {
                    Text("显示：\(filter.rawValue)")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(.body)
                .frame(minHeight: 44)
            }
            .accessibilityLabel("显示下载：\(filter.rawValue)")
        } else {
            Picker("显示下载", selection: $filter) {
                ForEach(DownloadFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
        }
    }

    private func requestDeletion(_ ids: Set<UUID>) {
        deletion = ids
        isDeletePresented = true
    }
}

private struct DownloadStorageSummary: View {
    let bytes: Int64
    let summary: DownloadSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已下载文件占用").font(.subheadline).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.title2.weight(.semibold)).monospacedDigit()
            if !summary.statusText.isEmpty {
                Text(summary.statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .listRowSeparator(.hidden)
    }
}

private struct DownloadWorkHeader<Actions: View>: View {
    let group: DownloadWorkGroup
    let isExpanded: Bool
    let openWork: () -> Void
    let toggle: () -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric private var coverSize = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if typeSize.isAccessibilitySize {
                workLink
                controls
            } else {
                HStack(alignment: .top, spacing: 8) {
                    workLink
                    controls
                }
            }
            if group.summary.hasUnfinished {
                Text(group.summary.statusText).font(.caption).foregroundStyle(.secondary)
                if let progress = group.summary.progress {
                    ProgressView(value: progress)
                        .accessibilityLabel("所选文件下载进度")
                } else {
                    HStack {
                        if group.summary.count(.downloading) > 0 {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        }
                        Text("部分文件大小未知").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var workLink: some View {
        Button(action: openWork) {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: group.saved.work.mainCoverURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "square.stack").font(.title2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: min(coverSize, 88), height: min(coverSize, 88))
                .background(Color(uiColor: .tertiarySystemFill))
                .clipShape(.rect(cornerRadius: 10))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.saved.work.title).font(.headline).foregroundStyle(.primary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                    Text(group.saved.work.rjCode).font(.caption).foregroundStyle(.secondary)
                    Text(group.summary.completionText).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开作品与文件目录")
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Menu(content: actions) {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }
            .accessibilityLabel("管理本作品全部所选文件")
            Button(action: toggle) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down").frame(width: 44, height: 44)
            }
            .accessibilityLabel(isExpanded ? "收起文件" : "展开文件")
        }
        .buttonStyle(.borderless)
    }
}

private struct DownloadManagementActions: View {
    let entries: [DownloadEntry]
    let downloads: DownloadStore
    let scope: String
    let delete: (Set<UUID>) -> Void
    var body: some View {
        Section(scope) {
            if entries.contains(where: { $0.state == .downloading }) {
                Button("暂停：\(scope)", systemImage: "pause") {
                    for entry in entries where entry.state == .downloading { downloads.pause(entry.id) }
                }
            }
            if entries.contains(where: { $0.state == .paused }) {
                Button("继续：\(scope)", systemImage: "play") {
                    for entry in entries where entry.state == .paused { downloads.resume(entry.id) }
                }
            }
            if entries.contains(where: { $0.state == .failed }) {
                Button("重试失败项：\(scope)", systemImage: "arrow.clockwise") {
                    for entry in entries where entry.state == .failed { downloads.retry(entry.id) }
                }
            }
            Button("删除：\(scope)", systemImage: "trash", role: .destructive) { delete(Set(entries.map(\.id))) }
        }
        .disabled(!downloads.isReady)
    }
}

private struct DownloadTaskRow: View {
    let entry: DownloadEntry
    let downloads: DownloadStore
    let delete: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize {
                fileLabel
                controls
            } else {
                HStack(alignment: .top, spacing: 8) {
                    fileLabel
                    controls
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    status
                    Spacer(minLength: 8)
                    Text(entry.sizeText).monospacedDigit().foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    status
                    Text(entry.sizeText).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            if entry.state == .downloading {
                if let progress = entry.progress {
                    ProgressView(value: progress).accessibilityLabel("文件下载进度")
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("文件大小未知")
                }
            }
            if entry.state == .failed, let error = entry.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private var fileLabel: some View {
        Label(entry.track.title, systemImage: entry.fileSymbol)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)
            .font(.subheadline.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: some View {
        Label(entry.displayStatus, systemImage: entry.state.symbol)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(entry.state == .failed ? Color.red : Color.secondary)
            .fixedSize()
    }

    private var controls: some View {
        HStack(spacing: 0) {
            switch entry.state {
            case .downloading:
                Button { downloads.pause(entry.id) } label: { actionLabel("暂停", "pause") }
            case .paused:
                Button { downloads.resume(entry.id) } label: { actionLabel("继续", "play") }
            case .failed:
                Button { downloads.retry(entry.id) } label: { actionLabel("重试", "arrow.clockwise") }
            case .completed: EmptyView()
            }
            Menu {
                Button("删除文件", systemImage: "trash", role: .destructive, action: delete)
            } label: { actionLabel("文件操作", "ellipsis") }
        }
        .buttonStyle(.borderless)
        .disabled(!downloads.isReady)
    }

    private func actionLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(width: 44, height: 44)
            .accessibilityLabel("\(title)：\(entry.track.title)")
    }
}
