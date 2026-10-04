#if DEBUG
import Foundation

extension DownloadStore {
    /// Only used by explicitly requested Debug preview screens in an isolated simulator.
    func prepareDebugDownloads() async throws {
        while !isReady { try await Task.sleep(for: .milliseconds(20)) }
        if ProcessInfo.processInfo.environment["WISIMI_DEBUG_SCREEN"] == "downloads-empty" {
            remove(Set(entries.map(\.id)))
            return
        }
        let fixtureIDs: Set<Int> = [99999999, 99999998, 99999997, 99999996]
        remove(Set(entries.filter { fixtureIDs.contains($0.workID) }.map(\.id)))
        let movie = try await DebugVideoFixture.make()
        let work = try JSONDecoder().decode(WorkDetail.self, from: Data(#"{"id":99999999,"title":"晚安陪伴 · 本地下载界面验证","name":"Wisimi","duration":8,"dl_count":1,"has_subtitle":true,"tags":[],"vas":[]}"#.utf8))
        let json = #"[{"type":"video","title":"01 晚安陪伴.mp4","hash":"preview-video","duration":8,"mediaDownloadUrl":"https://example.com/wisimi.mp4"},{"type":"text","title":"01 晚安陪伴.vtt","hash":"preview-subtitle","mediaDownloadUrl":"https://example.com/wisimi.vtt"},{"type":"audio","title":"02 雨声与轻声耳语 · 下载中.mp3","hash":"preview-active","duration":600,"mediaDownloadUrl":"https://example.com/active.mp3"},{"type":"audio","title":"03 漫长的夜晚 · 已暂停.mp3","hash":"preview-paused","duration":1200,"mediaDownloadUrl":"https://example.com/paused.mp3"},{"type":"audio","title":"04 失败后可重新尝试.mp3","hash":"preview-failed","mediaDownloadUrl":"https://example.com/failed.mp3"},{"type":"folder","title":"附加文件","children":[{"type":"image","title":"cover.png","mediaDownloadUrl":"https://example.com/cover.png"}]}]"#
        let tracks = try JSONDecoder().decode([TrackNode].self, from: Data(json.utf8))
        let localSubtitle = movie.deletingLastPathComponent().appendingPathComponent("check.vtt")
        try "WEBVTT\n\n00:00.000 --> 00:08.000\n这是一段已经缓存的字幕。\n".write(to: localSubtitle, atomically: true, encoding: .utf8)
        try seedDebugEntries(work: work, tracks: tracks, files: [movie, localSubtitle])
        guard ProcessInfo.processInfo.environment["WISIMI_DEBUG_SCREEN"]?.hasPrefix("downloads") == true else { return }
        func fixtureWork(id: Int, title: String) throws -> WorkDetail {
            let json: [String: Any] = ["id": id, "title": title, "name": "布局验证", "dl_count": 1,
                                       "has_subtitle": false, "tags": [], "vas": []]
            return try JSONDecoder().decode(WorkDetail.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let unknown = try JSONDecoder().decode([TrackNode].self, from: Data(#"[{"type":"audio","title":"等待传输 · 大小未知.mp3","hash":"unknown-size","mediaDownloadUrl":"https://example.com/unknown.mp3"},{"type":"audio","title":"这是一个用于验证小屏幕和辅助功能大字体自动换行的很长文件名称 · 耳边细语与雨声.mp3","hash":"long-title","mediaDownloadUrl":"https://example.com/long.mp3","size":20000000}]"#.utf8))
        try seedDebugEntries(work: fixtureWork(id: 99999998, title: "雨声与耳边细语 · 未知文件大小"), tracks: unknown, files: [], states: [.downloading, .paused])
        try seedDebugEntries(work: fixtureWork(id: 99999997, title: "已保存的晚安陪伴"), tracks: Array(tracks.prefix(2)), files: [movie, localSubtitle], states: [.completed, .completed])
        if ProcessInfo.processInfo.environment["WISIMI_DEBUG_SCREEN"] == "downloads-many" {
            let many = (1...80).map { index in
                ["type": "audio", "title": "第 \(index) 个文件 · 长列表滚动验证.mp3", "hash": "many-\(index)",
                 "mediaDownloadUrl": "https://example.com/many-\(index).mp3", "size": 20_000_000] as [String: Any]
            }
            let files = try JSONDecoder().decode([TrackNode].self, from: JSONSerialization.data(withJSONObject: many))
            try seedDebugEntries(work: fixtureWork(id: 99999996, title: "大量文件布局与滚动验证"), tracks: files, files: [], states: Array(repeating: .paused, count: files.count))
        }
    }
}
#endif
