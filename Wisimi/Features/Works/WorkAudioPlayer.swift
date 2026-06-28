import AVFoundation
import Combine
import Foundation

@MainActor
final class WorkAudioPlayer: ObservableObject {
    @Published var queue: [TrackNode] = []
    @Published var currentIndex = 0
    @Published var workID: Int?
    @Published var workTitle = ""
    @Published var circleName = ""
    @Published var coverURL: URL?
    @Published var position: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isPlaying = false
    @Published var subtitles: [SubtitleLine] = []
    @Published var currentSubtitleIndex: Int?

    private let client: ASMRClient
    private let player = AVPlayer()
    private var siblings: [TrackNode] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?

    init(client: ASMRClient) {
        self.client = client
        configureAudioSession()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncProgress() }
        }
    }

    var currentTrack: TrackNode? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    var currentSubtitle: SubtitleLine? {
        guard let currentSubtitleIndex, subtitles.indices.contains(currentSubtitleIndex) else { return nil }
        return subtitles[currentSubtitleIndex]
    }

    func play(queue: [TrackNode], start track: TrackNode, siblings: [TrackNode], work: WorkDetail) {
        guard let index = queue.firstIndex(where: { $0.id == track.id }), queue[index].audioURL != nil else { return }
        self.queue = queue
        self.siblings = siblings
        currentIndex = index
        workID = work.id
        workTitle = work.title
        circleName = work.name
        coverURL = work.mainCoverURL
        loadCurrent(siblings: siblings, autoPlay: true)
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        currentIndex = max(currentIndex - 1, 0)
        loadCurrent(siblings: siblings, autoPlay: true)
    }

    func next() {
        guard currentIndex + 1 < queue.count else {
            player.pause()
            isPlaying = false
            return
        }
        currentIndex += 1
        loadCurrent(siblings: siblings, autoPlay: true)
    }

    func seek(to seconds: TimeInterval) {
        let target = max(0, min(seconds, duration))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        position = target
        updateSubtitle()
    }

    func seek(to subtitle: SubtitleLine) {
        seek(to: subtitle.start)
    }

    private func loadCurrent(siblings: [TrackNode], autoPlay: Bool) {
        loadTask?.cancel()
        guard let track = currentTrack, let url = track.audioURL else { return }

        endObserver.map(NotificationCenter.default.removeObserver)
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        position = 0
        duration = track.duration ?? 0
        subtitles = []
        currentSubtitleIndex = nil
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.next() }
        }

        loadTask = Task { [client] in
            let subtitle = Self.matchSubtitle(for: track, in: siblings)
            guard let url = subtitle?.downloadURL, let content = try? await client.fetchText(url), !Task.isCancelled else { return }
            let lines = Self.parseSubtitles(content)
            await MainActor.run {
                guard self.currentTrack?.id == track.id else { return }
                self.subtitles = lines
                self.updateSubtitle()
            }
        }

        if autoPlay {
            player.play()
            isPlaying = true
        }
    }

    private func syncProgress() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite {
            position = seconds
        }
        let itemDuration = player.currentItem?.duration.seconds
        if let itemDuration, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        isPlaying = player.timeControlStatus == .playing
        updateSubtitle()
    }

    private func updateSubtitle() {
        currentSubtitleIndex = subtitles.lastIndex { position >= $0.start && position < $0.end }
    }

    private func configureAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    private static func matchSubtitle(for audio: TrackNode, in siblings: [TrackNode]) -> TrackNode? {
        let base = audio.title.deletingPathExtension.lowercased()
        let subtitleFiles = siblings.filter(\.isSubtitle)
        return subtitleFiles.first { $0.title.lowercased() == "\(base).vtt" || $0.title.lowercased() == "\(base).lrc" }
            ?? subtitleFiles.first { file in
                let subtitleBase = file.title.deletingPathExtension.lowercased()
                return subtitleBase.hasPrefix(base) || base.hasPrefix(subtitleBase)
            }
    }

    fileprivate static func parseSubtitles(_ content: String) -> [SubtitleLine] {
        content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT")
            ? parseVTT(content)
            : parseLRC(content)
    }

    private static func parseVTT(_ content: String) -> [SubtitleLine] {
        let blocks = content.components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.split(whereSeparator: \.isNewline).map(String.init)
            guard let timing = lines.first(where: { $0.contains("-->") }) else { return nil }
            let parts = timing.components(separatedBy: "-->")
            guard parts.count == 2, let start = parseTimestamp(parts[0]), let end = parseTimestamp(parts[1]) else { return nil }
            let text = lines.drop(while: { !$0.contains("-->") }).dropFirst().joined(separator: "\n")
            return text.isEmpty ? nil : SubtitleLine(start: start, end: end, text: text)
        }
    }

    private static func parseLRC(_ content: String) -> [SubtitleLine] {
        let regex = try? NSRegularExpression(pattern: #"\[(\d{2}):(\d{2})\.(\d{2})\]"#)
        var lines: [SubtitleLine] = []

        for row in content.components(separatedBy: .newlines) {
            let range = NSRange(row.startIndex..<row.endIndex, in: row)
            let matches = regex?.matches(in: row, range: range) ?? []
            let text = regex?.stringByReplacingMatches(in: row, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !matches.isEmpty, !text.isEmpty else { continue }
            for match in matches {
                guard let minutes = Int(row[match.range(at: 1)]),
                      let seconds = Int(row[match.range(at: 2)]),
                      let centiseconds = Int(row[match.range(at: 3)]) else { continue }
                let start = Double(minutes * 60 + seconds) + Double(centiseconds) / 100
                lines.append(SubtitleLine(start: start, end: start + 5, text: text))
            }
        }

        lines.sort { $0.start < $1.start }
        for index in lines.indices.dropLast() {
            lines[index].end = lines[index + 1].start
        }
        return lines
    }

    private static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ").first ?? raw
        let parts = cleaned.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count >= 2 else { return nil }
        let secondsPart = parts.last?.split(separator: ".") ?? []
        guard let secondsText = secondsPart.first, let seconds = Double(secondsText) else { return nil }
        let fraction = secondsPart.dropFirst().first.map { Double("0.\($0)") ?? 0 } ?? 0
        let minutes = Double(parts[parts.count - 2]) ?? 0
        let hours = parts.count == 3 ? (Double(parts[0]) ?? 0) : 0
        return hours * 3600 + minutes * 60 + seconds + fraction
    }
}

struct SubtitleLine: Identifiable, Hashable {
    let id = UUID()
    let start: TimeInterval
    var end: TimeInterval
    let text: String
}

private extension String {
    var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }

    subscript(_ range: NSRange) -> String {
        guard let range = Range(range, in: self) else { return "" }
        return String(self[range])
    }
}

#if DEBUG
enum AudioPlayerSelfCheck {
    static func run() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:02.500
        hello
        """
        let lrc = "[00:01.50]hello\n[00:03.00]next"

        assert(WorkAudioPlayer.parseSubtitles(vtt).first?.start == 1)
        let lines = WorkAudioPlayer.parseSubtitles(lrc)
        assert(lines.count == 2)
        assert(lines[0].end == 3)
    }
}
#endif
