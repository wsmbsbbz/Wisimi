#if DEBUG
import Foundation

enum VideoTrackSelfCheck {
    static func run() {
        let json = #"[{"type":"audio","title":"01.mp3","hash":"a","mediaStreamUrl":"https://example.com/a.mp3"},{"type":"other","title":"02.MP4","hash":"v","mediaDownloadUrl":"https://example.com/v.mp4"},{"type":"video","title":"03.movie","hash":"v2","mediaStreamUrl":"https://example.com/stream","mediaDownloadUrl":"https://example.com/download"},{"type":"audio","title":"04.mp4","hash":"v3","mediaStreamUrl":"https://example.com/v3.mp4"},{"type":"text","title":"02.vtt","hash":"s","mediaDownloadUrl":"https://example.com/02.vtt"},{"type":"image","title":"cover.jpg","hash":"i","mediaDownloadUrl":"https://example.com/cover.jpg"},{"type":"video","title":"missing.mp4","hash":"missing"},{"type":"folder","title":"folder.mp4","hash":"folder"}]"#
        let tracks = try! JSONDecoder().decode([TrackNode].self, from: Data(json.utf8))
        assert(tracks.playableTracks.map(\.id) == ["a", "v", "v2", "v3"])
        assert(tracks[1].isVideo && tracks[1].playbackURL?.absoluteString == "https://example.com/v.mp4")
        assert(tracks[2].isVideo && tracks[2].playbackURL?.absoluteString == "https://example.com/stream")
        assert(tracks[3].isVideo && !tracks[3].isAudio)
        assert(tracks[4].playbackURL == nil && tracks[5].imagePreviewURL != nil)
        assert(tracks[6].isVideo && tracks[6].playbackURL == nil)
        assert(!tracks[7].isVideo && !tracks[7].isPlayable)
        print("Video track checks passed")
    }
}
#endif
