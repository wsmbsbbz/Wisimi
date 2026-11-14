import SwiftUI
import UniformTypeIdentifiers

struct LocalWorksView: View {
    let library: LocalWorkLibrary
    let catalog: any WorkCatalog
    let refreshID: Int?
    let reservesMiniPlayerSpace: Bool
    var importTrigger: Int = 0
    let openWork: (WorkReference) -> Void

    @State private var downloads = DownloadStore.shared
    @State private var page: WorkCatalogPage?
    @State private var loadRequest = UUID()
    @State private var requestedPage = 1
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var scrollPosition = ScrollPosition()
    @State private var showsPicker = false
    @State private var confirmsImport = false
    @State private var plan: LocalImportPlan?
    @State private var importTask: Task<Void, Never>?
    @State private var syncTask: Task<Void, Never>?
    @State private var importStatus: String?
    @State private var importError: String?

    var body: some View {
        let globalSummary = DownloadSummary(entries: downloads.entries)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                storageSummary

                if let importStatus {
                    HStack {
                        ProgressView(importStatus)
                        Spacer()
                        Button("取消") { importTask?.cancel() }
                            .frame(minHeight: 44)
                    }
                }

                if globalSummary.hasUnfinished {
                    LocalDownloadStatusCard(summary: globalSummary, downloads: downloads)
                }

                if let downloadMessage = downloads.message {
                    InfoCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(downloadMessage)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                            Button("关闭提示") { downloads.message = nil }
                                .frame(minHeight: 44)
                        }
                    }
                }

                if let loadError {
                    RetryView(message: loadError) { await load(requestedPage, refresh: true) }
                }
                if page == nil, loadError == nil {
                    ProgressView("读取本地作品…")
                        .frame(maxWidth: .infinity)
                } else if let page {
                    if page.unreadableCount > 0 {
                        Text("有 \(page.unreadableCount) 部作品无法读取。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if page.works.isEmpty, loadError == nil, page.unreadableCount == 0 {
                        ContentUnavailableView("还没有本地作品", systemImage: "folder",
                                               description: Text("从「文件」导入，或在在线作品详情中选择文件下载。"))
                    } else if !page.works.isEmpty {
                        MasonryGrid(works: page.works, onSelect: openWork)
                            .id(page.pagination.currentPage)
                        if page.pagination.totalPages > 1 {
                            PaginationControls(currentPage: page.pagination.currentPage, totalPages: page.pagination.totalPages,
                                               isLoading: isLoading) { number in
                                Task { await load(number, scrollToTop: true) }
                            }
                        }
                    }
                }
                if reservesMiniPlayerSpace {
                    Color.clear.frame(height: miniPlayerAvoidanceHeight)
                }
            }
            .padding(16)
        }
        .scrollPosition($scrollPosition)
        .task(id: refreshID) {
            if refreshID != nil {
                await load(page?.pagination.currentPage ?? 1, refresh: page != nil)
                triggerPendingDLsiteSync()
            }
        }
        .onChange(of: downloads.catalogRevision) {
            Task { await load(page?.pagination.currentPage ?? 1, refresh: true) }
        }
        .onChange(of: importTrigger) {
            if importTask == nil {
                showsPicker = true
            }
        }
        .refreshable {
            await load(page?.pagination.currentPage ?? 1, refresh: true)
            triggerPendingDLsiteSync()
        }
        .fileImporter(isPresented: $showsPicker, allowedContentTypes: [.folder], onCompletion: inspectSelection)
        .confirmationDialog("导入作品副本", isPresented: $confirmsImport, titleVisibility: .visible, presenting: plan) { plan in
            Button("复制并导入") { runImportTask("正在复制作品…") { try await importWork(plan) } }
        } message: { plan in
            let size = ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)
            Text("\(plan.title)预计占用 \(size)。导入后可离线播放，原文件会保留。")
        }
        .alert("导入失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    @ViewBuilder
    private var storageSummary: some View {
        if let page, page.pagination.totalCount > 0 {
            let sizeText = ByteCountFormatter.string(fromByteCount: page.totalBytes, countStyle: .file)
            Text("共 \(page.pagination.totalCount) 部 · 占用 \(sizeText)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func load(_ number: Int, refresh: Bool = false, scrollToTop: Bool = false) async {
        let request = UUID()
        loadRequest = request
        requestedPage = number
        isLoading = true
        defer { if loadRequest == request { isLoading = false } }
        do {
            let result = try await catalog.page(number, pageSize: 12, refresh: refresh)
            guard loadRequest == request, !Task.isCancelled else { return }
            page = result
            loadError = nil
            if scrollToTop || result.pagination.currentPage != number {
                scrollPosition.scrollTo(edge: .top)
            }
        } catch {
            guard loadRequest == request, !Task.isCancelled else { return }
            loadError = error.userFacingMessage
        }
    }

    private func inspectSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            runImportTask("正在读取文件夹…") {
                plan = try await library.inspect(url)
                try Task.checkCancellation()
                confirmsImport = true
            }
        case .failure(let error):
            importError = error.userFacingMessage
        }
    }

    private func importWork(_ plan: LocalImportPlan) async throws {
        _ = try await library.importWork(plan)
        await load(1, scrollToTop: true)
        triggerPendingDLsiteSync()
    }

    private func triggerPendingDLsiteSync() {
        guard syncTask == nil else { return }
        syncTask = Task {
            defer { syncTask = nil }
            let updated = await library.syncPendingDLsiteMetadataIfNeeded()
            guard updated, !Task.isCancelled else { return }
            await load(page?.pagination.currentPage ?? 1)
        }
    }

    private func runImportTask(_ status: String, operation: @escaping @MainActor () async throws -> Void) {
        guard importTask == nil else { return }
        importStatus = status
        importTask = Task {
            defer { importTask = nil; importStatus = nil }
            do { try await operation() }
            catch is CancellationError {}
            catch { importError = error.userFacingMessage }
        }
    }
}

private struct LocalDownloadStatusCard: View {
    let summary: DownloadSummary
    let downloads: DownloadStore
    var localWorkID: UUID? = nil

    private var isWorkScoped: Bool { localWorkID != nil }

    var body: some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(isWorkScoped ? summary.completionText : "\(summary.unfinishedWorkCount) 部作品有未完成下载")
                    .font(isWorkScoped ? .headline : .subheadline.weight(.semibold))
                if !summary.statusText.isEmpty {
                    Text(summary.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let progress = summary.progress {
                    ProgressView(value: progress)
                        .accessibilityLabel("\(isWorkScoped ? "作品下载进度" : "总下载进度") \(Int((progress * 100).rounded()))%")
                } else if summary.count(.downloading) > 0 {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("部分文件大小未知")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ChipFlowLayout(spacing: 8) {
                    if summary.count(.downloading) > 0 {
                        Button(isWorkScoped ? "暂停全部" : "全部暂停", systemImage: "pause") {
                            downloads.pauseAll(localWorkID: localWorkID)
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                    }
                    if summary.count(.paused) > 0 {
                        Button(isWorkScoped ? "继续全部" : "全部继续", systemImage: "play") {
                            downloads.resumeAll(localWorkID: localWorkID)
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                    }
                    if summary.count(.failed) > 0 {
                        Button(isWorkScoped ? "重试失败项" : "重试失败", systemImage: "arrow.clockwise") {
                            downloads.retryFailed(localWorkID: localWorkID)
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                    }
                }
                .disabled(!downloads.isReady)
            }
        }
    }
}

struct LocalWorkDetailView: View {
    let id: UUID
    let source: WorkSource
    let player: WorkAudioPlayer
    let reservesMiniPlayerSpace: Bool
    var onOpenOnlineWork: ((Int) -> Void)? = nil
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var downloads = DownloadStore.shared
    @State private var loaded: SourceWork?
    @State private var currentPath: [TrackNode] = []
    @State private var isPathMenuExpanded = false
    @State private var loadError: String?
    @State private var deleteError: String?
    @State private var confirmsRemoval = false
    @State private var isRemoving = false
    @State private var pendingEntryDeletion: DownloadEntry?

    private var onlineWorkID: Int? {
        loaded?.onlineWorkID ?? downloads.savedWork(localWorkID: id)?.work.id
    }

    var body: some View {
        Group {
            if let loaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        DetailHero(work: loaded.work)
                        sourceSection
                        if let warning = loaded.metadataWarning {
                            Text(warning).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let summary = downloads.summary(forLocalWork: id), summary.hasUnfinished {
                            LocalDownloadStatusCard(summary: summary, downloads: downloads, localWorkID: id)
                        }
                        InfoCard {
                            TrackBrowserView(
                                work: loaded.work,
                                tracks: loaded.tracks,
                                currentPath: $currentPath,
                                isPathMenuExpanded: $isPathMenuExpanded,
                                player: player,
                                localWorkID: onlineWorkID != nil ? id : nil,
                                onDeleteEntry: { entry in pendingEntryDeletion = entry }
                            )
                        }
                        if reservesMiniPlayerSpace {
                            Color.clear.frame(height: miniPlayerAvoidanceHeight)
                        }
                    }
                    .padding()
                }
            } else if let loadError {
                RetryView(message: loadError) { await load() }
            } else {
                ProgressView("加载详情中…")
            }
        }
        .navigationTitle("本地作品")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("删除本地副本", systemImage: "trash", role: .destructive) { confirmsRemoval = true }
                } label: {
                    Label("作品操作", systemImage: "ellipsis.circle")
                }
                .disabled(loaded == nil || isRemoving)
            }
        }
        .confirmationDialog("删除本地副本？", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("删除本地副本", role: .destructive) { Task { await remove() } }
        } message: {
            Text(onlineWorkID != nil
                 ? "将取消未完成的下载并删除已下载的文件，可在在线详情中重新下载。"
                 : "将删除 Wisimi 中导入的文件，原文件会保留。")
        }
        .alert("删除文件「\(pendingEntryDeletion?.track.title ?? "")」？", isPresented: Binding(
            get: { pendingEntryDeletion != nil },
            set: { if !$0 { pendingEntryDeletion = nil } }
        ), presenting: pendingEntryDeletion) { entry in
            Button("删除文件", role: .destructive) {
                Task { await deleteEntry(entry) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("将取消下载或删除本地文件；如这是本作品最后一个文件，作品也会一并移除。")
        }
        .alert("删除失败", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .task { if loaded == nil { await load() } }
        .onChange(of: downloads.catalogRevision) {
            guard loaded != nil, !isRemoving else { return }
            Task { await reloadPreservingPath() }
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        if let onlineID = onlineWorkID {
            InfoCard {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        onlineSourceLabel(onlineID)
                        onlineDetailButton(onlineID)
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            onlineSourceLabel(onlineID)
                            Spacer(minLength: 8)
                            onlineDetailButton(onlineID)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            onlineSourceLabel(onlineID)
                            onlineDetailButton(onlineID)
                        }
                    }
                }
            }
        } else {
            Label("从文件导入", systemImage: "folder")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func onlineSourceLabel(_ onlineID: Int) -> some View {
        Label("来自 asmr.one · RJ\(String(onlineID))", systemImage: "arrow.down.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func onlineDetailButton(_ onlineID: Int) -> some View {
        if let onOpenOnlineWork {
            Button("查看在线详情") { onOpenOnlineWork(onlineID) }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
        }
    }

    private func load() async {
        loadError = nil
        do {
            let work = try await source.loadWork(.local(id))
            try Task.checkCancellation()
            currentPath = work.tracks.defaultDirectoryPath
            loaded = work
        } catch is CancellationError {
        } catch {
            loadError = error.userFacingMessage
        }
    }

    private func reloadPreservingPath() async {
        if onlineWorkID != nil, downloads.savedWork(localWorkID: id) == nil {
            return
        }
        do {
            let previousIDs = currentPath.map(\.id)
            let work = try await source.loadWork(.local(id))
            try Task.checkCancellation()
            currentPath = work.tracks.resolvingDirectoryPath(ids: previousIDs) ?? work.tracks.defaultDirectoryPath
            loaded = work
        } catch {}
    }

    private func deleteEntry(_ entry: DownloadEntry) async {
        downloads.message = nil
        downloads.remove([entry.id])
        if let error = downloads.message {
            deleteError = error
            downloads.message = nil
            return
        }
        player.removeLocalWorkFromPlayback(id, trackID: entry.trackID)
        if downloads.savedWork(localWorkID: id) == nil {
            try? await source.library.remove(id)
            onDeleted()
            dismiss()
        } else {
            await source.library.invalidateCatalog()
            await reloadPreservingPath()
        }
    }

    private func remove() async {
        guard !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }
        do {
            if downloads.savedWork(localWorkID: id) != nil {
                downloads.removeWork(localWorkID: id)
            }
            try await source.library.remove(id)
            player.removeLocalWorkFromPlayback(id)
            onDeleted()
            dismiss()
        } catch {
            deleteError = error.userFacingMessage
        }
    }
}
