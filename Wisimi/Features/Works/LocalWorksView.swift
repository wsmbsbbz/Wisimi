import SwiftUI
import UniformTypeIdentifiers

struct LocalWorksView: View {
    let library: LocalWorkLibrary
    let refreshID: Int?
    let openWork: (UUID) -> Void

    @State private var entries: [LocalWorkEntry] = []
    @State private var search = ""
    @State private var loadError: String?
    @State private var isLoaded = false
    @State private var showsPicker = false
    @State private var confirmsImport = false
    @State private var plan: LocalImportPlan?
    @State private var importTask: Task<Void, Never>?
    @State private var importStatus: String?
    @State private var importError: String?

    private var visibleEntries: [LocalWorkEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? entries : entries.filter { $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    showsPicker = true
                } label: {
                    Label("导入作品", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(importTask != nil)

                if let importStatus {
                    HStack {
                        ProgressView(importStatus)
                        Spacer()
                        Button("取消") { importTask?.cancel() }
                    }
                }

                if !entries.isEmpty {
                    TextField("搜索本地作品", text: $search)
                        .textFieldStyle(.roundedBorder)
                }

                if let loadError {
                    RetryView(message: loadError) { await reload() }
                }
                if !isLoaded {
                    ProgressView("读取本地作品…")
                        .frame(maxWidth: .infinity)
                } else if entries.isEmpty, loadError == nil {
                    ContentUnavailableView("还没有本地作品", systemImage: "folder", description: Text("从「文件」选择一个作品文件夹。"))
                } else if visibleEntries.isEmpty, loadError == nil {
                    ContentUnavailableView.search(text: search)
                }

                LazyVStack(spacing: 8) {
                    ForEach(visibleEntries) { entry in
                        let work = entry.presentation(in: library.contentDirectory(for: entry.id))
                        Button { openWork(entry.id) } label: {
                            HStack(spacing: 12) {
                                CoverImage(url: work.coverURL, cornerRadius: 8, size: CGSize(width: 58, height: 58),
                                           placeholderWhenMissing: true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(work.title).font(.headline)
                                    if let circle = work.circle {
                                        Text(circle).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(.thinMaterial, in: .rect(cornerRadius: 12))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: refreshID) { if refreshID != nil { await reload() } }
        .refreshable { await reload() }
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

    private func reload() async {
        do {
            let result = try await library.list()
            guard !Task.isCancelled else { return }
            entries = result
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.userFacingMessage
        }
        isLoaded = true
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
        let entry = try await library.importWork(plan)
        await reload()
        search = ""
        openWork(entry.id)
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

struct LocalWorkDetailView: View {
    let id: UUID
    let source: WorkSource
    let player: WorkAudioPlayer
    let reservesMiniPlayerSpace: Bool
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var loaded: SourceWork?
    @State private var currentPath: [TrackNode] = []
    @State private var isPathMenuExpanded = false
    @State private var loadError: String?
    @State private var deleteError: String?
    @State private var confirmsRemoval = false
    @State private var isRemoving = false

    var body: some View {
        Group {
            if let loaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        DetailHero(work: loaded.work)
                        if let warning = loaded.metadataWarning {
                            Text(warning).font(.footnote).foregroundStyle(.secondary)
                        }
                        InfoCard {
                            TrackBrowserView(work: loaded.work, tracks: loaded.tracks, currentPath: $currentPath,
                                             isPathMenuExpanded: $isPathMenuExpanded, player: player)
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
            Text("将删除 Wisimi 中导入的文件，原文件会保留。")
        }
        .alert("删除失败", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .task { if loaded == nil { await load() } }
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

    private func remove() async {
        guard !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }
        do {
            try await source.library.remove(id)
            player.removeLocalWorkFromPlayback(id)
            onDeleted()
            dismiss()
        } catch {
            deleteError = error.userFacingMessage
        }
    }
}
