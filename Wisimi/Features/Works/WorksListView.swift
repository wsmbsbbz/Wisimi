import SwiftUI

struct WorksListView: View {
    @State private var works: [WorkSummary] = []
    @State private var pagination: WorksPagination?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedWorkID: Int?
    @State private var currentPage = 1

    private let client = ASMRClient()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && works.isEmpty {
                    ProgressView("加载作品中...")
                } else if let errorMessage, works.isEmpty {
                    RetryView(message: errorMessage) {
                        await loadWorks(page: currentPage)
                    }
                } else if works.isEmpty {
                    EmptyStateView {
                        await loadWorks(page: 1)
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Color.clear
                                .frame(height: 0)
                                .id("top")

                            VStack(spacing: 18) {
                                MasonryGrid(works: works) { work in
                                    selectedWorkID = work.id
                                }

                                PaginationControls(
                                    currentPage: currentPage,
                                    totalPages: pagination?.totalPages,
                                    isLoading: isLoading
                                ) { page in
                                    Task {
                                        await loadWorks(page: page)
                                        withAnimation {
                                            proxy.scrollTo("top", anchor: .top)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .background(.background)
                        .refreshable {
                            await loadWorks(page: 1)
                            withAnimation {
                                proxy.scrollTo("top", anchor: .top)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Wisimi")
            .toolbar {
                if isLoading && !works.isEmpty {
                    ProgressView()
                }
            }
            .navigationDestination(isPresented: isShowingDetail) {
                if let selectedWorkID {
                    WorkDetailView(workID: selectedWorkID, client: client)
                }
            }
        }
        .task {
            await loadWorks(page: currentPage)
        }
    }

    private var isShowingDetail: Binding<Bool> {
        Binding {
            selectedWorkID != nil
        } set: { isPresented in
            if !isPresented {
                selectedWorkID = nil
            }
        }
    }

    private func loadWorks(page: Int = 1) async {
        guard !isLoading else { return }
        if let totalPages = pagination?.totalPages, page > totalPages { return }
        guard page >= 1 else { return }

        isLoading = true
        errorMessage = nil
        do {
            let response = try await client.fetchWorks(page: page)
            works = response.works
            pagination = response.pagination
            currentPage = response.pagination.currentPage
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct MasonryGrid: View {
    private let columnSpacing: CGFloat = 12
    private let rowSpacing: CGFloat = 12

    let works: [WorkSummary]
    let onSelect: (WorkSummary) -> Void
    @State private var availableWidth: CGFloat = 0

    private var leftColumn: [WorkSummary] {
        works.enumerated().compactMap { index, work in
            index.isMultiple(of: 2) ? work : nil
        }
    }

    private var rightColumn: [WorkSummary] {
        works.enumerated().compactMap { index, work in
            index.isMultiple(of: 2) ? nil : work
        }
    }

    private var columnWidth: CGFloat {
        max(floor((availableWidth - columnSpacing) / 2), 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    availableWidth = width
                }

            if columnWidth > 0 {
                HStack(alignment: .top, spacing: columnSpacing) {
                    column(leftColumn)
                    column(rightColumn)
                }
                .frame(width: availableWidth, alignment: .leading)
                .clipped()
            }
        }
    }

    private func column(_ works: [WorkSummary]) -> some View {
        LazyVStack(spacing: rowSpacing) {
            ForEach(works) { work in
                Button {
                    onSelect(work)
                } label: {
                    WorkRow(work: work, width: columnWidth)
                }
                .buttonStyle(.plain)
                .frame(width: columnWidth)
                .clipped()
            }
        }
        .frame(width: columnWidth, alignment: .top)
        .clipped()
    }
}

private struct PaginationControls: View {
    let currentPage: Int
    let totalPages: Int?
    let isLoading: Bool
    let onPageChanged: (Int) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button {
                onPageChanged(currentPage - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(currentPage <= 1 || isLoading)

            Text("\(currentPage)/\(totalPages.map(String.init) ?? "?")")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 64)

            Button {
                onPageChanged(currentPage + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(totalPages.map { currentPage >= $0 } ?? true || isLoading)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

#Preview {
    WorksListView()
}
