#if DEBUG
import Foundation

extension DownloadStore {
    /// Only used by explicitly requested Debug preview screens in an isolated simulator.
    func prepareDebugDownloads() async throws {
        while !isReady { try await Task.sleep(for: .milliseconds(20)) }
        let movie = try await DebugVideoFixture.make()
        let work = try JSONDecoder().decode(WorkDetail.self, from: Data(#"{"id":99999999,"title":"晚安陪伴 · 本地下载界面验证","name":"Wisimi","duration":8,"dl_count":1,"has_subtitle":true,"tags":[],"vas":[]}"#.utf8))
        let json = #"[{"type":"video","title":"01 晚安陪伴.mp4","hash":"preview-video","duration":8,"mediaDownloadUrl":"https://example.com/wisimi.mp4"},{"type":"text","title":"01 晚安陪伴.vtt","hash":"preview-subtitle","mediaDownloadUrl":"https://example.com/wisimi.vtt"},{"type":"audio","title":"02 雨声与轻声耳语 · 下载中.mp3","hash":"preview-active","duration":600,"mediaDownloadUrl":"https://example.com/active.mp3"},{"type":"audio","title":"03 漫长的夜晚 · 已暂停.mp3","hash":"preview-paused","duration":1200,"mediaDownloadUrl":"https://example.com/paused.mp3"},{"type":"audio","title":"04 失败后可重新尝试.mp3","hash":"preview-failed","mediaDownloadUrl":"https://example.com/failed.mp3"},{"type":"folder","title":"附加文件","children":[{"type":"image","title":"cover.png","mediaDownloadUrl":"https://example.com/cover.png"}]}]"#
        let tracks = try JSONDecoder().decode([TrackNode].self, from: Data(json.utf8))
        let localSubtitle = movie.deletingLastPathComponent().appendingPathComponent("check.vtt")
        try "WEBVTT\n\n00:00.000 --> 00:08.000\n这是一段已经缓存的字幕。\n".write(to: localSubtitle, atomically: true, encoding: .utf8)
        try seedDebugEntries(work: work, tracks: tracks, files: [movie, localSubtitle])
    }
}
#endif
