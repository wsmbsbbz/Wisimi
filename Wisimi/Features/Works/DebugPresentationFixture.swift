#if DEBUG
import SwiftUI

/// Exercises the real controls without login or remote mutations.
struct DebugWorkActionsPreview: View {
    @State private var isMarkMenuPresented = false
    @State private var isPlaylistMenuPresented = false
    @State private var isFilterPresented = false
    @State private var isLoading = false
    @State private var currentStatus: ReviewStatus?
    @State private var catalog = PlaylistCatalog(client: DebugSheetFixture.client())
    private let client = DebugSheetFixture.client()

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
                        currentStatus: currentStatus, isLoggedIn: true, isLoading: isLoading,
                        isMenuPresented: $isMarkMenuPresented, message: nil,
                        onLoginRequired: {},
                        onStatusSelected: { currentStatus = $0 }
                    )
                    PlaylistActionButton(
                        workID: 0, client: client, token: DebugSheetFixture.token,
                        isMenuPresented: $isPlaylistMenuPresented,
                        onLoginRequired: {}
                    )
                    Button("打开播放列表筛选") { isFilterPresented = true }
                        .buttonStyle(.bordered)
                    Toggle("模拟标记加载中", isOn: $isLoading)
                    Text("当前标记：\(currentStatus?.title ?? "无")")
                        .font(.caption)
                }
                .padding(16)
            }
            .navigationTitle("操作区域验收")
            .sheet(isPresented: $isFilterPresented) {
                WorksFilterSheet(
                    context: .playlists, filter: .default, reviewFilter: .default, catalog: catalog,
                    token: DebugSheetFixture.token, onApply: { _ in }, onApplyReviewFilter: { _ in },
                    onApplyPlaylist: { _ in }, onCatalogChanged: {}
                )
                .presentationDetents([.medium, .large])
            }
            .task {
                _ = try? await catalog.ensureSelection(token: DebugSheetFixture.token)
            }
        }
    }
}

private enum DebugSheetFixture {
    static let token = "debug"

    static func client() -> ASMRClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DebugSheetProtocol.self]
        return ASMRClient(session: URLSession(configuration: configuration))
    }
}

/// 两页播放列表；添加成功，移除固定失败，用于验收乐观更新回滚和弹层内错误。
private final class DebugSheetProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        if url.path.hasSuffix("remove-works-from-playlist") {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let json: String
        if url.path.hasSuffix("add-works-to-playlist") {
            json = #"{"id":"debug","rowCount":1}"#
        } else {
            let page = url.query?.contains("page=2") == true ? 2 : 1
            let rows = page == 1
                ? [#"{"id":"liked","name":"__SYS_PLAYLIST_LIKED","privacy":0,"description":"","works_count":12,"exist":true}"#,
                   #"{"id":"sleep","name":"睡前","privacy":0,"description":"","works_count":3,"exist":false}"#,
                   #"{"id":"long","name":"一个名字特别长的播放列表，用来检查不同屏幕宽度和大字号下的换行","privacy":0,"description":"","works_count":1,"exist":true}"#]
                : [#"{"id":"rain","name":"雨声","privacy":0,"description":"","works_count":5,"exist":false}"#]
            json = #"{"playlists":[\#(rows.joined(separator: ","))],"pagination":{"currentPage":\#(page),"pageSize":3,"totalCount":4}}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
