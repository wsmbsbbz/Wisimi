import AVFoundation
import Combine
import Foundation
#if os(iOS)
import MediaPlayer
import UIKit
#endif

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
    @Published private(set) var narrationStatuses: [SubtitleLine.ID: TTSGenerationStatus] = [:]

    private let client: ASMRClient
    private let ttsSettings: TTSMixSettings
    private let ttsClient = EdgeOnlineTTSClient()
    private let player = AVPlayer()
    private let narrationPlayer = AVPlayer()
    private var siblings: [TrackNode] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var playerStatusCancellable: AnyCancellable?
    private var settingsCancellables: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    private var narrationTask: Task<Void, Never>?
    private var narrationCutoffTask: Task<Void, Never>?
    private var prefetchTasks: [SubtitleLine.ID: Task<Void, Never>] = [:]
    private var artworkTask: Task<Void, Never>?
    private var nowPlayingArtworkURL: URL?
    private var wasPlayingBeforeInterruption = false
    private var isActivatingAudioSession = false
    private var shouldPlayAfterActivation = false
    private var lastSavedPosition: TimeInterval = -1
    private var lastNarrationID: String?

    init(client: ASMRClient, ttsSettings: TTSMixSettings) {
        self.client = client
        self.ttsSettings = ttsSettings
        configureAudioSession()
        configureRemoteCommands()
        observeAudioSession()
        narrationPlayer.volume = Float(ttsSettings.volume)
        playerStatusCancellable = player.publisher(for: \.timeControlStatus)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncProgress() }
            }
        ttsSettings.$volume
            .sink { [weak self] volume in
                self?.narrationPlayer.volume = Float(volume)
            }
            .store(in: &settingsCancellables)
        ttsSettings.$isEnabled
            .sink { [weak self] isEnabled in
                guard !isEnabled else { return }
                self?.stopNarration(clearLast: true)
                self?.cancelPrefetchTasks()
                self?.narrationStatuses = [:]
            }
            .store(in: &settingsCancellables)
        ttsSettings.$maxSpeechRate
            .sink { [weak self] _ in
                guard let self else { return }
                stopNarration(clearLast: true)
                cancelPrefetchTasks()
                refreshCachedNarrationStatuses()
                syncNarration()
            }
            .store(in: &settingsCancellables)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncProgress() }
        }
        Task { await restorePlayback() }
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
            pauseCurrent()
        } else {
            playCurrent()
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        currentIndex = max(currentIndex - 1, 0)
        loadCurrent(siblings: siblings, autoPlay: true)
    }

    func next() {
        guard currentIndex + 1 < queue.count else {
            pauseCurrent()
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
        stopNarration(clearLast: true)
        syncNarration()
        updateNowPlaying()
        savePlayback(force: true)
    }

    func seek(to subtitle: SubtitleLine) {
        seek(to: subtitle.start)
    }

    private func loadCurrent(siblings: [TrackNode], autoPlay: Bool, resumePosition: TimeInterval = 0) {
        loadTask?.cancel()
        guard let track = currentTrack, let url = track.audioURL else { return }

        endObserver.map(NotificationCenter.default.removeObserver)
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        stopNarration(clearLast: true)
        cancelPrefetchTasks()
        narrationStatuses = [:]
        position = max(0, min(resumePosition, track.duration ?? resumePosition))
        duration = track.duration ?? 0
        subtitles = []
        currentSubtitleIndex = nil
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        savePlayback(force: true)
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
                self.refreshCachedNarrationStatuses()
                self.updateSubtitle()
                self.syncNarration()
            }
        }

        if autoPlay {
            playCurrent()
        } else {
            updateNowPlaying()
        }
    }

    private func syncProgress() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite, position != seconds {
            position = seconds
        }
        let itemDuration = player.currentItem?.duration.seconds
        if let itemDuration, itemDuration.isFinite, itemDuration > 0, duration != itemDuration {
            duration = itemDuration
        }
        let isCurrentlyPlaying = player.timeControlStatus == .playing
        if isPlaying != isCurrentlyPlaying {
            isPlaying = isCurrentlyPlaying
        }
        updateSubtitle()
        syncNarration()
        prefetchUpcomingNarration()
        updateNowPlaying()
        savePlayback()
    }

    private func updateSubtitle() {
        let index = Self.currentSubtitleIndex(at: position, in: subtitles)
        if currentSubtitleIndex != index {
            currentSubtitleIndex = index
        }
    }

    fileprivate static func currentSubtitleIndex(at position: TimeInterval, in subtitles: [SubtitleLine]) -> Int? {
        subtitles.lastIndex { position >= $0.start }
    }

    private func savePlayback(force: Bool = false) {
        guard let workID, let currentTrack else { return }
        guard force || abs(position - lastSavedPosition) >= 5 || lastSavedPosition < 0 else { return }
        lastSavedPosition = position
        let snapshot = PlaybackSnapshot(
            workID: workID,
            trackID: currentTrack.id,
            position: position,
            workTitle: workTitle,
            circleName: circleName,
            coverURL: coverURL?.absoluteString
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: PlaybackSnapshot.storageKey)
    }

    private func restorePlayback() async {
        guard let data = UserDefaults.standard.data(forKey: PlaybackSnapshot.storageKey),
              let snapshot = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data),
              let detail = try? await client.fetchWork(id: snapshot.workID),
              let tracks = try? await client.fetchTracks(workID: snapshot.workID),
              let context = Self.playbackContext(for: snapshot.trackID, in: tracks) else { return }

        queue = context.queue
        siblings = context.siblings
        currentIndex = context.index
        workID = detail.id
        workTitle = detail.title
        circleName = detail.name
        coverURL = detail.mainCoverURL ?? snapshot.coverURL.flatMap(URL.init(string:))
        loadCurrent(siblings: context.siblings, autoPlay: false, resumePosition: snapshot.position)
    }

    fileprivate static func playbackContext(for trackID: String, in nodes: [TrackNode]) -> (queue: [TrackNode], siblings: [TrackNode], index: Int)? {
        let queue = nodes.filter { $0.isAudio && $0.audioURL != nil }
        if let index = queue.firstIndex(where: { $0.id == trackID }) {
            return (queue, nodes, index)
        }

        for node in nodes {
            if let children = node.children,
               let context = playbackContext(for: trackID, in: children) {
                return context
            }
        }
        return nil
    }

    private func configureAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        #endif
    }

    private func playCurrent() {
        shouldPlayAfterActivation = true
        activateAudioSession { [weak self] activated in
            guard let self, activated, self.shouldPlayAfterActivation else { return }
            shouldPlayAfterActivation = false
            player.play()
            syncProgress()
        }
    }

    private func pauseCurrent() {
        shouldPlayAfterActivation = false
        player.pause()
        stopNarration(clearLast: true)
        syncProgress()
    }

    private func syncNarration() {
        guard ttsSettings.isEnabled, isPlaying, let currentTrack else {
            stopNarration(clearLast: false)
            return
        }
        guard let currentSubtitleIndex, subtitles.indices.contains(currentSubtitleIndex) else {
            stopNarration(clearLast: true)
            return
        }

        let subtitle = subtitles[currentSubtitleIndex]
        let text = subtitle.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let narrationID = "\(currentTrack.id)|\(subtitle.start)|\(text)"
        guard lastNarrationID != narrationID else { return }
        lastNarrationID = narrationID
        stopNarration(clearLast: false)
        prefetchTasks[subtitle.id]?.cancel()
        prefetchTasks[subtitle.id] = nil

        let speechRate = ttsSettings.maxSpeechRate
        let outputURL = EdgeOnlineTTSClient.cacheURL(for: text, speechRate: speechRate)
        let cutoff = narrationCutoff(forSubtitleAt: currentSubtitleIndex)
        narrationStatuses[subtitle.id] = FileManager.default.fileExists(atPath: outputURL.path) ? .ready : .generating
        narrationTask = Task { [ttsClient] in
            do {
                try await ttsClient.synthesizeToFile(text: text, speechRate: speechRate, outputURL: outputURL)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.narrationStatuses[subtitle.id] = .ready
                    guard self.ttsSettings.isEnabled,
                          self.isPlaying,
                          self.currentNarrationID() == narrationID else { return }
                    let item = AVPlayerItem(url: outputURL)
                    self.narrationPlayer.replaceCurrentItem(with: item)
                    self.narrationPlayer.volume = Float(self.ttsSettings.volume)
                    self.narrationPlayer.play()
                    self.scheduleNarrationCutoff(at: cutoff, narrationID: narrationID)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.narrationStatuses[subtitle.id] = .failed
                    guard self.currentNarrationID() == narrationID else { return }
                    self.lastNarrationID = nil
                }
            }
        }
    }

    private func stopNarration(clearLast: Bool) {
        narrationTask?.cancel()
        narrationTask = nil
        narrationCutoffTask?.cancel()
        narrationCutoffTask = nil
        narrationPlayer.pause()
        narrationPlayer.replaceCurrentItem(with: nil)
        if clearLast {
            lastNarrationID = nil
        }
    }

    private func prefetchUpcomingNarration() {
        guard ttsSettings.isEnabled, let currentSubtitleIndex else { return }
        let indices = Self.prefetchIndices(after: currentSubtitleIndex, subtitleCount: subtitles.count)
        for index in indices {
            prefetchNarration(at: index)
        }
    }

    private func prefetchNarration(at index: Int) {
        guard subtitles.indices.contains(index) else { return }
        let subtitle = subtitles[index]
        let text = subtitle.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let speechRate = ttsSettings.maxSpeechRate
        let outputURL = EdgeOnlineTTSClient.cacheURL(for: text, speechRate: speechRate)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            narrationStatuses[subtitle.id] = .ready
            return
        }
        guard prefetchTasks[subtitle.id] == nil else { return }

        narrationStatuses[subtitle.id] = .generating
        prefetchTasks[subtitle.id] = Task { [ttsClient] in
            do {
                try await ttsClient.synthesizeToFile(text: text, speechRate: speechRate, outputURL: outputURL)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.prefetchTasks[subtitle.id] = nil
                    self.narrationStatuses[subtitle.id] = .ready
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.prefetchTasks[subtitle.id] = nil
                    self.narrationStatuses[subtitle.id] = .failed
                }
            }
        }
    }

    private func cancelPrefetchTasks() {
        for task in prefetchTasks.values {
            task.cancel()
        }
        prefetchTasks = [:]
    }

    private func refreshCachedNarrationStatuses() {
        let speechRate = ttsSettings.maxSpeechRate
        narrationStatuses = Dictionary(uniqueKeysWithValues: subtitles.compactMap { subtitle in
            let text = subtitle.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let url = EdgeOnlineTTSClient.cacheURL(for: text, speechRate: speechRate)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (subtitle.id, TTSGenerationStatus.ready)
        })
    }

    fileprivate static func prefetchIndices(after index: Int, subtitleCount: Int) -> [Int] {
        guard subtitleCount > 0 else { return [] }
        let start = index + 1
        guard start < subtitleCount else { return [] }
        let end = min(index + 5, subtitleCount - 1)
        return Array(start...end)
    }

    private func scheduleNarrationCutoff(at cutoff: TimeInterval, narrationID: String) {
        narrationCutoffTask?.cancel()
        let delay = max(0, cutoff - position)
        narrationCutoffTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            await MainActor.run {
                guard self.currentNarrationID() == narrationID else { return }
                self.stopNarration(clearLast: false)
            }
        }
    }

    private func narrationCutoff(forSubtitleAt index: Int) -> TimeInterval {
        let nextIndex = subtitles.index(after: index)
        if subtitles.indices.contains(nextIndex) {
            return subtitles[nextIndex].start
        }
        return duration > 0 ? duration : subtitles[index].end
    }

    private func currentNarrationID() -> String? {
        guard let currentTrack,
              let currentSubtitleIndex,
              subtitles.indices.contains(currentSubtitleIndex) else { return nil }
        let subtitle = subtitles[currentSubtitleIndex]
        let text = subtitle.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return "\(currentTrack.id)|\(subtitle.start)|\(text)"
    }

    private func activateAudioSession(then action: @escaping @MainActor (Bool) -> Void) {
        #if os(iOS)
        guard !isActivatingAudioSession else { return }
        isActivatingAudioSession = true
        AVAudioSession.sharedInstance().activate(options: []) { [weak self] activated, error in
            Task { @MainActor in
                guard let self else { return }
                self.isActivatingAudioSession = false
                if let error {
                    print("Audio session activation failed: \(error.localizedDescription)")
                }
                action(activated)
            }
        }
        #else
        action(true)
        #endif
    }

    private func updateNowPlaying() {
        #if os(iOS)
        guard let currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = currentTrack.title
        info[MPMediaItemPropertyAlbumTitle] = workTitle
        info[MPMediaItemPropertyArtist] = circleName
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1 : 0
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtworkIfNeeded()
        #endif
    }

    private func loadArtworkIfNeeded() {
        #if os(iOS)
        guard nowPlayingArtworkURL != coverURL else { return }
        nowPlayingArtworkURL = coverURL
        artworkTask?.cancel()
        guard let coverURL else { return }

        artworkTask = Task { [coverURL] in
            guard let (data, _) = try? await URLSession.shared.data(from: coverURL),
                  !Task.isCancelled,
                  let image = UIImage(data: data) else { return }

            await MainActor.run {
                guard self.coverURL == coverURL else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
        #endif
    }

    private func configureRemoteCommands() {
        #if os(iOS)
        let commands = MPRemoteCommandCenter.shared()

        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playCurrent() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pauseCurrent() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
        #endif
    }

    private func observeAudioSession() {
        #if os(iOS)
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

            Task { @MainActor in
                switch type {
                case .began:
                    self.wasPlayingBeforeInterruption = self.isPlaying
                    self.pauseCurrent()
                case .ended:
                    let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                    if options.contains(.shouldResume), self.wasPlayingBeforeInterruption {
                        self.playCurrent()
                    } else {
                        self.updateNowPlaying()
                    }
                    self.wasPlayingBeforeInterruption = false
                @unknown default:
                    self.updateNowPlaying()
                }
            }
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else { return }
            let previousRoute = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            guard previousRoute?.outputs.contains(where: \.isDisconnectableAudioOutput) == true else { return }
            Task { @MainActor in self?.pauseCurrent() }
        }
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

private struct PlaybackSnapshot: Codable {
    static let storageKey = "WorkAudioPlayer.playbackSnapshot"

    let workID: Int
    let trackID: String
    let position: TimeInterval
    let workTitle: String
    let circleName: String
    let coverURL: String?
}

enum TTSGenerationStatus {
    case generating
    case ready
    case failed
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

#if os(iOS)
private extension AVAudioSessionPortDescription {
    var isDisconnectableAudioOutput: Bool {
        [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones].contains(portType)
    }
}
#endif

#if DEBUG
enum AudioPlayerSelfCheck {
    static func run() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:02.500
        hello

        00:00:04.000 --> 00:00:05.000
        next
        """
        let lrc = "[00:01.50]hello\n[00:03.00]next"

        assert(WorkAudioPlayer.parseSubtitles(vtt).first?.start == 1)
        assert(WorkAudioPlayer.currentSubtitleIndex(at: 3.5, in: WorkAudioPlayer.parseSubtitles(vtt)) == 0)
        let lines = WorkAudioPlayer.parseSubtitles(lrc)
        assert(lines.count == 2)
        assert(lines[0].end == 3)
        assert(WorkAudioPlayer.currentSubtitleIndex(at: 2.9, in: lines) == 0)
        assert(WorkAudioPlayer.prefetchIndices(after: 0, subtitleCount: 10) == [1, 2, 3, 4, 5])
        assert(WorkAudioPlayer.prefetchIndices(after: 8, subtitleCount: 10) == [9])
        assert(WorkAudioPlayer.prefetchIndices(after: 9, subtitleCount: 10).isEmpty)

        let tracksJSON = #"[{"type":"folder","title":"root","children":[{"type":"audio","title":"01.mp3","hash":"a","duration":10,"mediaDownloadUrl":"https://example.com/a.mp3"},{"type":"audio","title":"02.mp3","hash":"b","duration":20,"mediaDownloadUrl":"https://example.com/b.mp3"}]}]"#
        let tracks = (try? JSONDecoder().decode([TrackNode].self, from: Data(tracksJSON.utf8))) ?? []
        let context = WorkAudioPlayer.playbackContext(for: "b", in: tracks)
        assert(context?.queue.count == 2)
        assert(context?.index == 1)
    }
}
#endif
