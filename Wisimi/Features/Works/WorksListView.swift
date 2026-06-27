import SwiftUI

struct WorksListView: View {
    @State private var works: [WorkSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedWorkID: Int?

    private let client = ASMRClient()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && works.isEmpty {
                    ProgressView("加载作品中...")
                } else if let errorMessage, works.isEmpty {
                    RetryView(message: errorMessage, retry: loadWorks)
                } else if works.isEmpty {
                    EmptyStateView(retry: loadWorks)
                } else {
                    List(works) { work in
                        Button {
                            selectedWorkID = work.id
                        } label: {
                            WorkRow(work: work)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(.background)
                    .refreshable {
                        await loadWorks()
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
            await loadWorks()
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

    private func loadWorks() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            works = try await client.fetchWorks()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    WorksListView()
}
