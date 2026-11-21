import AVFoundation
import Foundation
import MediaPlayer
import Testing
@testable import Wisimi

@Suite("Audio Player Integration", .serialized)
@MainActor
struct AudioPlayerIntegrationTests {
    private static func makePlayer() -> WorkAudioPlayer {
        let source = WorkSource(online: OnlineWorkSource(client: makeStubClient()), library: .shared)
        return WorkAudioPlayer(source: source, ttsSettings: TTSMixSettings())
    }

    @Test func subtitleParsingAndPrefetchIndices() throws {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:02.500
        hello

        00:00:04.000 --> 00:00:05.000
        next
        """
        let lrc = "[00:01.50]hello\n[00:03.00]next"

        #expect(WorkAudioPlayer.parseSubtitles(vtt).first?.start == 1)
        #expect(WorkAudioPlayer.currentSubtitleIndex(at: 3.5, in: WorkAudioPlayer.parseSubtitles(vtt)) == 0)
        let lines = WorkAudioPlayer.parseSubtitles(lrc)
        #expect(lines.count == 2)
        #expect(lines[0].end == 3)
        #expect(WorkAudioPlayer.currentSubtitleIndex(at: 2.9, in: lines) == 0)
        #expect(WorkAudioPlayer.prefetchIndices(after: 0, subtitleCount: 10) == [1, 2, 3, 4, 5])
        #expect(WorkAudioPlayer.prefetchIndices(after: 8, subtitleCount: 10) == [9])
        #expect(WorkAudioPlayer.prefetchIndices(after: 9, subtitleCount: 10).isEmpty)

        let tracksJSON = #"[{"type":"folder","title":"root","children":[{"type":"audio","title":"01.mp3","hash":"a","duration":10,"mediaDownloadUrl":"https://example.com/a.mp3"},{"type":"audio","title":"02.mp3","hash":"b","duration":20,"mediaDownloadUrl":"https://example.com/b.mp3"}]}]"#
        let tracks = try JSONDecoder().decode([TrackNode].self, from: Data(tracksJSON.utf8))
        let context = WorkAudioPlayer.playbackContext(for: "b", in: tracks)
        #expect(context?.queue.count == 2)
        #expect(context?.index == 1)
    }

    @Test func narrationCutoffAndStaleStateReset() async throws {
        let player = Self.makePlayer()
        try await player.runNarrationChecks()
    }

    @Test func videoPlaybackAndSurfaceLifecycle() async throws {
        let player = Self.makePlayer()
        try await player.runVideoChecks()
    }

    @Test func playbackAndSleepTimerIntegration() async throws {
        let player = Self.makePlayer()
        try await player.runPlaybackChecks()
    }

    @Test func localMediaAndCachedNarration() async throws {
        let player = Self.makePlayer()
        try await player.runLocalMediaChecks(mp3: TestFixtures.silenceMP3URL)
    }

    @Test func downloadedMediaPlayback() async throws {
        let player = Self.makePlayer()
        try await player.runDownloadedMediaCheck()
    }
}
