import AVFoundation
import Combine
import Foundation
#if os(iOS)
import MediaPlayer
import UIKit
#endif

@MainActor
final class WorkAudioPlayer: ObservableObject {
    @Published private(set) var queue: [TrackNode] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var workReference: WorkReference?
    @Published private(set) var workTitle = ""
    @Published private(set) var circleName = ""
    @Published private(set) var coverURL: URL?
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackState: PlaybackState = .paused
    @Published private(set) var playbackError: String?
    @Published private(set) var sleepTimer: SleepTimer = .off
    private var sleepTimerTask: Task<Void, Never>?
    @Published private(set) var subtitles: [SubtitleLine] = []
    @Published private(set) var currentSubtitleIndex: Int?
    @Published private(set) var narrationState: NarrationState = .off

    private let source: WorkSource
    private let ttsSettings: TTSMixSettings
    private let synthesis = TTSCoordinator()
    private let player = AVPlayer()
    private let narrationPlayer = AVPlayer()
    private var siblings: [TrackNode] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var itemStatusCancellable: AnyCancellable?
    private var interruptionObserver: NSObjectProtocol?
    private var resumptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var playerStatusCancellable: AnyCancellable?
    private var settingsCancellables: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    private var durationLoadTask: Task<Void, Never>?
    private var narrationTask: Task<Void, Never>?
    private var narrationCutoffTask: Task<Void, Never>?
    private var prefetchTasks: [SubtitleLine.ID: Task<Void, Never>] = [:]
    private var artworkTask: Task<Void, Never>?
    private var nowPlayingArtworkURL: URL?
    private var wasPlayingBeforeInterruption = false
    private var isActivatingAudioSession = false
    private var lastSavedPosition: TimeInterval = -1
    private var lastNarrationID: String?
    private var activeSeekID: UInt64 = 0
    private var isSeekingPlayer = false

    init(source: WorkSource, ttsSettings: TTSMixSettings) {
        self.source = source
        self.ttsSettings = ttsSettings
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        configureAudioSession()
        configureRemoteCommands()
        observeAudioSession()
        narrationPlayer.volume = Float(ttsSettings.volume)
        narrationState = ttsSettings.isEnabled ? .enabled : .off
        playerStatusCancellable = player.publisher(for: \.timeControlStatus)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.syncProgress() }
            }
        ttsSettings.$volume
            .sink { [weak self] volume in
                self?.narrationPlayer.volume = Float(volume)
            }
            .store(in: &settingsCancellables)
        ttsSettings.$isEnabled
            .sink { [weak self] isEnabled in
                guard let self else { return }
                if isEnabled {
                    narrationState = .enabled
                    Task { @MainActor [weak self] in
                        self?.syncNarration()
                        self?.prefetchUpcomingNarration()
                    }
                } else {
                    stopNarration(clearLast: true)
                    cancelPrefetchTasks()
                    synthesis.reset()
                    narrationState = .off
                }
            }
            .store(in: &settingsCancellables)
        ttsSettings.$configuration
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reloadNarrationConfiguration() }
            }
            .store(in: &settingsCancellables)
        ttsSettings.$credentialRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.resetOpenRouterSession()
                self?.reloadNarrationConfiguration()
            }
            .store(in: &settingsCancellables)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.syncProgress() }
        }
        Task { await restorePlayback() }
    }

    isolated deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for observer in [endObserver, failureObserver, interruptionObserver, resumptionObserver, routeChangeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        sleepTimerTask?.cancel()
        loadTask?.cancel()
        durationLoadTask?.cancel()
        narrationTask?.cancel()
        narrationCutoffTask?.cancel()
        artworkTask?.cancel()
        cancelPrefetchTasks()
    }

    var videoPlayer: AVPlayer { player }

    var currentTrack: TrackNode? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    var currentSubtitle: SubtitleLine? {
        guard let currentSubtitleIndex, subtitles.indices.contains(currentSubtitleIndex) else { return nil }
        return subtitles[currentSubtitleIndex]
    }

    func play(queue: [TrackNode], start track: TrackNode, siblings: [TrackNode], work: WorkPresentation) {
        guard let index = queue.firstIndex(where: { $0.id == track.id }), queue[index].playbackURL != nil else { return }
        if sleepTimer == .endOfTrack { setSleepTimer(.off) }
        self.queue = queue
        self.siblings = siblings
        currentIndex = index
        workReference = work.reference
        workTitle = work.title
        circleName = work.circle ?? ""
        coverURL = work.coverURL
        resetOpenRouterSession()
        loadCurrent(siblings: siblings, autoPlay: true)
    }

    func removeLocalWorkFromPlayback(_ id: UUID, trackID: String? = nil) {
        if workReference == .local(id) {
            if let trackID, let currentID = currentTrack?.id, currentID != trackID,
               let updatedQueue = Optional(queue.filter { $0.id != trackID }), !updatedQueue.isEmpty,
               let newIndex = updatedQueue.firstIndex(where: { $0.id == currentID }) {
                queue = updatedQueue
                siblings.removeAll { $0.id == trackID }
                currentIndex = newIndex
            } else {
                pauseCurrent()
                setSleepTimer(.off)
                loadTask?.cancel()
                durationLoadTask?.cancel()
                player.replaceCurrentItem(with: nil)
                queue = []
                siblings = []
                currentIndex = 0
                workReference = nil
                workTitle = ""
                circleName = ""
                coverURL = nil
                position = 0
                duration = 0
                subtitles = []
                currentSubtitleIndex = nil
                playbackError = nil
                #if os(iOS)
                artworkTask?.cancel()
                nowPlayingArtworkURL = nil
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                #endif
            }
        }
        if let data = UserDefaults.standard.data(forKey: PlaybackSnapshot.storageKey),
           let snapshot = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data),
           snapshot.localWorkID == id,
           trackID == nil || snapshot.trackID == trackID {
            UserDefaults.standard.removeObject(forKey: PlaybackSnapshot.storageKey)
        }
    }

    func togglePlayback() {
        if playbackState.wantsPlayback {
            pauseCurrent()
        } else {
            playCurrent()
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if sleepTimer == .endOfTrack { setSleepTimer(.off) }
        currentIndex = max(currentIndex - 1, 0)
        loadCurrent(siblings: siblings, autoPlay: true)
    }

    func next() {
        if sleepTimer == .endOfTrack { setSleepTimer(.off) }
        guard currentIndex + 1 < queue.count else {
            pauseCurrent()
            return
        }
        currentIndex += 1
        loadCurrent(siblings: siblings, autoPlay: true)
    }

    func seek(to seconds: TimeInterval) {
        let target = max(0, min(seconds, duration))
        seekPlayer(to: target)
        position = target
        updateSubtitle()
        stopNarration(clearLast: true)
        cancelPrefetchTasks()
        syncNarration()
        updateNowPlaying()
        savePlayback(force: true)
    }

    private func seekPlayer(to seconds: TimeInterval) {
        activeSeekID &+= 1
        let seekID = activeSeekID
        guard player.currentItem != nil, seconds.isFinite else {
            isSeekingPlayer = false
            return
        }
        isSeekingPlayer = true
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeSeekID == seekID else { return }
                self.isSeekingPlayer = false
            }
        }
    }

    func seek(to subtitle: SubtitleLine) {
        seek(to: subtitle.start)
    }

    private func loadCurrent(siblings: [TrackNode], autoPlay: Bool, resumePosition: TimeInterval = 0) {
        loadTask?.cancel()
        durationLoadTask?.cancel()
        guard let track = currentTrack,
              let url = track.playbackURL else { return }

        endObserver.map(NotificationCenter.default.removeObserver)
        failureObserver.map(NotificationCenter.default.removeObserver)
        itemStatusCancellable = nil
        playbackError = nil
        activeSeekID &+= 1
        isSeekingPlayer = false
        playbackState = autoPlay ? .preparing : .paused
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        stopNarration(clearLast: true)
        cancelPrefetchTasks()
        resetOpenRouterSession()
        narrationState = ttsSettings.isEnabled ? .enabled : .off
        position = max(0, min(resumePosition, track.duration ?? resumePosition))
        duration = track.duration ?? 0
        if url.isFileURL, duration == 0 {
            // A restored item stays paused, so its playback clock may never publish a tick.
            durationLoadTask = Task { [weak self] in
                guard let seconds = try? await item.asset.load(.duration).seconds,
                      seconds.isFinite, seconds > 0, !Task.isCancelled,
                      let self, self.player.currentItem === item, self.duration == 0 else { return }
                self.duration = seconds
                self.updateNowPlaying()
            }
        }
        subtitles = []
        currentSubtitleIndex = nil
        seekPlayer(to: position)
        savePlayback(force: true)
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.player.currentItem === item else { return }
                guard self.playbackState.wantsPlayback else { return }
                self.trackDidEnd()
            }
        }
        itemStatusCancellable = item.publisher(for: \.status).sink { [weak self, weak item] status in
            guard status == .failed else { return }
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else { return }
                self.failPlayback(item.error?.userFacingMessage ?? "媒体加载失败，请重试")
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.userFacingMessage
            Task { @MainActor in
                guard self.player.currentItem === item else { return }
                self.failPlayback(message ?? "媒体播放失败，请重试")
            }
        }

        loadTask = Task {
            guard let subtitle = siblings.matchingSubtitle(for: track),
                  let url = subtitle.downloadSourceURL,
                  let content = try? await source.subtitleText(at: url), !Task.isCancelled else { return }
            let lines = SubtitleParser.parse(content)
            await MainActor.run {
                guard self.currentTrack?.id == track.id else { return }
                self.subtitles = lines
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
        guard !stopIfSleepTimerExpired() else { return }
        let seconds = player.currentTime().seconds
        if !isSeekingPlayer, seconds.isFinite, position != seconds {
            position = seconds
        }
        let itemDuration = player.currentItem?.duration.seconds
        if let itemDuration, itemDuration.isFinite, itemDuration > 0, duration != itemDuration {
            duration = itemDuration
        }
        switch player.timeControlStatus {
        case .playing: playbackState = playbackState.receiving(.outputStarted)
        case .waitingToPlayAtSpecifiedRate: playbackState = playbackState.receiving(.waiting)
        case .paused: break
        @unknown default: break
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

    static func currentSubtitleIndex(at position: TimeInterval, in subtitles: [SubtitleLine]) -> Int? {
        subtitles.lastIndex { position >= $0.start }
    }

    #if DEBUG
    func runLocalMediaChecks(mp3: URL) async throws {
        let files = FileManager.default
        let movie = try await DebugVideoFixture.make()
        let root = movie.deletingLastPathComponent()
        let input = root.appendingPathComponent("无元信息作品/音轨", isDirectory: true)
        let library = LocalWorkLibrary(directory: root.appendingPathComponent("Library"), requiresSecurityScope: false)
        let testSource = WorkSource(client: source.client, library: library)
        let saved = UserDefaults.standard.data(forKey: PlaybackSnapshot.storageKey)
        let settingsSuite = "Wisimi.local-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: settingsSuite)!
        let settings = TTSMixSettings(defaults: defaults)
        let text = "本地旁白自检 \(UUID().uuidString)"
        let cache = TTSCache.url(for: settings.synthesisRequest(text: text))
        defer {
            UserDefaults.standard.set(saved, forKey: PlaybackSnapshot.storageKey)
            defaults.removePersistentDomain(forName: settingsSuite)
            try? files.removeItem(at: cache)
            try? files.removeItem(at: root)
        }
        UserDefaults.standard.removeObject(forKey: PlaybackSnapshot.storageKey)
        try files.createDirectory(at: input, withIntermediateDirectories: true)
        try files.copyItem(at: movie, to: input.appendingPathComponent("01.mp4"))
        try files.copyItem(at: root.appendingPathComponent("sound.caf"), to: input.appendingPathComponent("02.caf"))
        try "WEBVTT\n\n00:00.000 --> 00:08.000\n\(text)\n".write(to: input.appendingPathComponent("01.vtt"), atomically: true, encoding: .utf8)
        try "[00:00.00]\(text)".write(to: input.appendingPathComponent("02.lrc"), atomically: true, encoding: .utf8)
        try files.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: mp3, to: cache)
        guard TTSCache.containsValidAudio(at: cache) else { throw URLError(.cannotDecodeContentData) }

        let original = input.deletingLastPathComponent()
        let plan = try await library.inspect(original)
        let entry = try await library.importWork(plan)
        let loaded = try await testSource.loadWork(.local(entry.id))
        let siblings = loaded.tracks[0].children!
        let tracks = siblings.playableTracks
        assert(entry.title == "无元信息作品" && tracks.count == 2)

        settings.isEnabled = true
        let test = WorkAudioPlayer(source: testSource, ttsSettings: settings)
        test.play(queue: tracks, start: tracks[0], siblings: siblings, work: loaded.work)
        for _ in 0..<100 {
            if test.playbackState == .playing, test.narrationPlayer.currentItem != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        assert(test.playbackState == .playing && test.playbackError == nil)
        assert(test.subtitles.first?.text == text && test.currentTrack?.isVideo == true)
        assert((test.narrationPlayer.currentItem?.asset as? AVURLAsset)?.url == cache)
        test.next()
        for _ in 0..<100 {
            if test.playbackState == .playing, test.duration > 4, test.subtitles.first?.text == text { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        assert(test.playbackState == .playing && test.currentTrack?.isAudio == true && test.subtitles.first?.text == text)
        test.pauseCurrent()
        settings.isEnabled = false
        test.seek(to: 3)

        let restored = WorkAudioPlayer(source: testSource, ttsSettings: settings)
        for _ in 0..<100 {
            if restored.duration > 4, abs(restored.player.currentTime().seconds - 3) < 0.1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        assert(restored.workReference == .local(entry.id) && restored.currentTrack?.id == tracks[1].id)
        assert(abs(restored.player.currentTime().seconds - 3) < 0.1 && restored.playbackState == .paused)
        assert(restored.duration > 4, "Paused restore must publish the actual duration without starting playback")
        restored.seek(to: 4)
        assert(restored.position == 4 && restored.playbackState == .paused)
        try await library.remove(entry.id)
        restored.removeLocalWorkFromPlayback(entry.id)
        assert(restored.currentTrack == nil && UserDefaults.standard.data(forKey: PlaybackSnapshot.storageKey) == nil)
        assert(files.fileExists(atPath: input.appendingPathComponent("01.mp4").path))
        NSLog("Local media checks passed: MP4, CAF, VTT/LRC, cached narration, resume, delete and original preservation")
    }

    func runDownloadedMediaCheck() async throws {
        try await DownloadStore.shared.prepareDebugDownloads()
        let saved = DownloadStore.shared.savedWork(id: 99999999)!
        let loaded = try await source.loadWork(.local(saved.localWorkID))
        let video = loaded.tracks[0]
        let localURL = DownloadStore.shared.localURL(for: video, workID: saved.id)!
        assert(video.playbackURL == localURL)
        ttsSettings.isEnabled = false
        play(queue: loaded.tracks.playableTracks, start: video, siblings: loaded.tracks, work: loaded.work)
        for _ in 0..<200 {
            if player.currentItem?.status == .readyToPlay && !subtitles.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        assert((player.currentItem?.asset as? AVURLAsset)?.url == localURL)
        assert(player.currentItem?.status == .readyToPlay)
        assert(subtitles.first?.text == "这是一段已经缓存的字幕。")
        assert(playbackError == nil)
        pauseCurrent()
        NSLog("Downloaded media integration checks passed: local MP4 decoding and cached subtitles")
    }
    #endif

    private func savePlayback(force: Bool = false) {
        guard let workReference, let currentTrack else { return }
        guard force || abs(position - lastSavedPosition) >= 5 || lastSavedPosition < 0 else { return }
        lastSavedPosition = position
        let snapshot = PlaybackSnapshot(
            workID: workReference.onlineID,
            localWorkID: workReference.localID,
            trackID: currentTrack.id,
            position: position,
            workTitle: workTitle,
            circleName: circleName,
            coverURL: workReference.onlineID == nil ? nil : coverURL?.absoluteString
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: PlaybackSnapshot.storageKey)
    }

    private func restorePlayback() async {
        guard let data = UserDefaults.standard.data(forKey: PlaybackSnapshot.storageKey),
              let snapshot = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data),
              let reference = snapshot.reference, currentTrack == nil,
              let loaded = try? await source.loadWork(reference) else { return }
        guard currentTrack == nil,
              UserDefaults.standard.data(forKey: PlaybackSnapshot.storageKey) == data,
              let context = Self.playbackContext(for: snapshot.trackID, in: loaded.tracks) else { return }
        let detail = loaded.work
        queue = context.queue
        siblings = context.siblings
        currentIndex = context.index
        workReference = detail.reference
        workTitle = detail.title
        circleName = detail.circle ?? ""
        coverURL = detail.coverURL ?? (reference.onlineID == nil ? nil : snapshot.coverURL.flatMap(URL.init(string:)))
        loadCurrent(siblings: context.siblings, autoPlay: false, resumePosition: snapshot.position)
    }

    static func playbackContext(for trackID: String, in nodes: [TrackNode]) -> (queue: [TrackNode], siblings: [TrackNode], index: Int)? {
        let queue = nodes.playableTracks
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

    func setSleepTimer(_ timer: SleepTimer) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimer = timer
        guard case .deadline(let deadline) = timer else { return }
        if stopIfSleepTimerExpired() { return }
        sleepTimerTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard let self, self.sleepTimer == timer else { return }
            self.setSleepTimer(.off)
            self.pauseCurrent()
        }
    }

    @discardableResult
    func stopIfSleepTimerExpired() -> Bool {
        guard sleepTimer.hasExpired() else { return false }
        setSleepTimer(.off)
        pauseCurrent()
        return true
    }

    private func trackDidEnd() {
        if sleepTimer == .endOfTrack {
            setSleepTimer(.off)
            pauseCurrent()
        } else {
            next()
        }
    }

    func retryPlayback() {
        loadCurrent(siblings: siblings, autoPlay: true, resumePosition: position)
    }

    private func playCurrent() {
        guard !stopIfSleepTimerExpired() else { return }
        guard currentTrack != nil else { return }
        if playbackError != nil {
            retryPlayback()
            return
        }
        playbackState = playbackState.receiving(.play)
        updateNowPlaying()
        activateAudioSession()
    }

    private func pauseCurrent(preservingInterruption: Bool = false) {
        if !preservingInterruption { wasPlayingBeforeInterruption = false }
        playbackState = playbackState.receiving(.pause)
        player.pause()
        narrationState = ttsSettings.isEnabled ? .enabled : .off
        stopNarration(clearLast: true)
        cancelPrefetchTasks()
        syncProgress()
        savePlayback(force: true)
    }

    private func failPlayback(_ message: String) {
        pauseCurrent()
        playbackError = message
    }

    private func syncNarration() {
        guard ttsSettings.isEnabled, playbackState == .playing, let currentTrack else {
            stopNarration(clearLast: false)
            return
        }
        guard let currentSubtitleIndex, subtitles.indices.contains(currentSubtitleIndex) else {
            stopNarration(clearLast: true)
            narrationState = .enabled
            return
        }

        let subtitle = subtitles[currentSubtitleIndex]
        let text = subtitle.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let synthesisRequest = ttsSettings.synthesisRequest(text: text)
        let narrationID = "\(currentTrack.id)|\(subtitle.start)|\(TTSCache.fingerprint(for: synthesisRequest))"
        guard lastNarrationID != narrationID else { return }
        lastNarrationID = narrationID
        stopNarration(clearLast: false)
        let cutoff = narrationCutoff(forSubtitleAt: currentSubtitleIndex)
        narrationState = synthesis.cachedAudio(for: synthesisRequest, hasCredential: ttsSettings.isOpenRouterConfigured) != nil ? .enabled : .preparing
        narrationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await synthesizeWithFallback(synthesisRequest)
                guard !Task.isCancelled else { return }
                guard ttsSettings.isEnabled,
                      playbackState == .playing,
                      currentNarrationID() == narrationID else { return }
                narrationState = audio.isFallback ? .fallback : .enabled
                if let notice = audio.notice { ttsSettings.runtimeNotice = notice }
                let item = AVPlayerItem(url: audio.url)
                narrationPlayer.replaceCurrentItem(with: item)
                narrationPlayer.volume = Float(ttsSettings.volume)
                narrationPlayer.play()
                scheduleNarrationCutoff(at: cutoff, narrationID: narrationID)
            } catch {
                guard !Task.isCancelled else { return }
                guard currentNarrationID() == narrationID else { return }
                narrationState = .failed(error.localizedDescription)
                ttsSettings.runtimeNotice = "旁白生成失败：\(error.localizedDescription)"
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
        guard ttsSettings.isEnabled, playbackState == .playing, let currentSubtitleIndex else { return }
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

        let synthesisRequest = ttsSettings.synthesisRequest(text: text)
        if synthesis.cachedAudio(for: synthesisRequest, hasCredential: ttsSettings.isOpenRouterConfigured) != nil {
            return
        }
        guard prefetchTasks[subtitle.id] == nil else { return }

        prefetchTasks[subtitle.id] = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await synthesizeWithFallback(synthesisRequest)
            } catch {
                // Current playback will surface a remembered failure, without hot-loop retries.
            }
        }
    }

    private func cancelPrefetchTasks() {
        for task in prefetchTasks.values {
            task.cancel()
        }
        prefetchTasks = [:]
        synthesis.cancelPending()
    }

    static func prefetchIndices(after index: Int, subtitleCount: Int) -> [Int] {
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
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
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
        let request = ttsSettings.synthesisRequest(text: text)
        return "\(currentTrack.id)|\(subtitle.start)|\(TTSCache.fingerprint(for: request))"
    }

    private func reloadNarrationConfiguration() {
        stopNarration(clearLast: true)
        cancelPrefetchTasks()
        synthesis.reset()
        narrationState = ttsSettings.isEnabled ? .enabled : .off
        syncNarration()
        prefetchUpcomingNarration()
    }

    private func resetOpenRouterSession() {
        synthesis.reset()
    }

    func retryNarration() {
        ttsSettings.runtimeNotice = nil
        reloadNarrationConfiguration()
    }

    private func synthesizeWithFallback(_ request: TTSSynthesisRequest) async throws -> TTSCoordinator.Audio {
        let credential = request.model == .edge ? nil : try ttsSettings.openRouterToken()
        return try await synthesis.audio(for: request, credential: credential)
    }

    private func activateAudioSession() {
        #if os(iOS)
        guard !isActivatingAudioSession else { return }
        isActivatingAudioSession = true
        AVAudioSession.sharedInstance().activate(options: []) { [weak self] activated, error in
            guard let self else { return }
            let message = error?.userFacingMessage
            Task { @MainActor in
                self.isActivatingAudioSession = false
                guard self.playbackState.wantsPlayback, !self.stopIfSleepTimerExpired() else { return }
                guard activated else {
                    self.failPlayback(message ?? "无法启用音频播放，请重试")
                    return
                }
                self.player.play()
                self.syncProgress()
            }
        }
        #else
        guard playbackState.wantsPlayback else { return }
        player.play()
        syncProgress()
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
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackState == .playing ? 1 : 0
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo?.removeValue(forKey: MPMediaItemPropertyArtwork)
        guard let coverURL else { return }

        artworkTask = Task { [coverURL] in
            let data = try? await Data.load(from: coverURL)
            guard let data, !Task.isCancelled,
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
            forName: AVAudioSession.didBecomeInactiveNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.wasPlayingBeforeInterruption = self.playbackState.wantsPlayback
                self.pauseCurrent(preservingInterruption: true)
            }
        }
        resumptionObserver = center.addObserver(
            forName: AVAudioSession.resumptionRecommendationNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            guard let self,
                  let context = notification.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext else { return }
            let shouldResume = context.recommendation == .shouldResume
            Task { @MainActor in
                let resume = shouldResume && self.wasPlayingBeforeInterruption
                self.wasPlayingBeforeInterruption = false
                if resume { self.playCurrent() }
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
            guard let self else { return }
            Task { @MainActor in self.pauseCurrent() }
        }
        #endif
    }

    #if DEBUG
    func prepareDebugNarrationPreview() throws {
        try prepareDebugPlayback()
        if ProcessInfo.processInfo.environment["WISIMI_DEBUG_NARRATION_DEMO"] == "1" {
            workTitle = "雨夜森林的耳语与篝火"
            circleName = "静夜工坊"
            subtitles = [
                SubtitleLine(start: 0, end: 6, text: "今夜は静かな雨音が森を包んでいます。"),
                SubtitleLine(start: 6, end: 13, text: "深く息を吸って、ゆっくり肩の力を抜いていきましょう。"),
                SubtitleLine(start: 13, end: 20, text: "パチパチと揺れる焚き火の音に、ただ耳を澄ませてみてください。"),
                SubtitleLine(start: 20, end: 26, text: "今日の疲れは、雨の音と一緒にそっと手放して大丈夫ですよ。"),
                SubtitleLine(start: 26, end: 30, text: "おやすみなさい、どうぞ穏やかな夢を。")
            ]
            currentSubtitleIndex = 1
        } else {
            subtitles = [
                SubtitleLine(start: 0, end: 4, text: "晚安，做个好梦。"),
                SubtitleLine(start: 4, end: 10, text: String(repeating: "这一句较长，用来检查窄屏与大字体下的完整换行，相邻字幕之间应保持清晰间距。", count: 4)),
                SubtitleLine(start: 10, end: 20, text: String(repeating: "LongSubtitleWithoutSpaces", count: 12)),
                SubtitleLine(start: 20, end: 28, text: "第一行：显式换行。\n第二行：完整显示。\n第三行：不覆盖下一条字幕。"),
                SubtitleLine(start: 28, end: 30, text: "点击周边空白返回封面。")
            ]
            currentSubtitleIndex = 0
        }
        narrationState = ProcessInfo.processInfo.environment["WISIMI_DEBUG_NARRATION_STATE"] == "enabled"
            ? .enabled : .failed("测试状态：网络暂不可用")
    }

    func runNarrationChecks() async throws {
        try prepareDebugPlayback()
        // Let the settings subscription finish initialization before installing the test item.
        try await Task.sleep(for: .milliseconds(100))
        let subtitle = SubtitleLine(start: 0, end: 30, text: "截止任务取消验证")
        subtitles = [subtitle]
        currentSubtitleIndex = 0
        let id = currentNarrationID()!
        narrationPlayer.replaceCurrentItem(with: AVPlayerItem(url: currentTrack!.playbackURL!))
        scheduleNarrationCutoff(at: 20, narrationID: id)
        scheduleNarrationCutoff(at: 20, narrationID: id)
        try await Task.sleep(for: .milliseconds(100))
        assert(narrationPlayer.currentItem != nil, "Cancelled cutoff must not stop the replacement narration")
        narrationState = .failed("旧曲失败")
        loadCurrent(siblings: queue, autoPlay: false)
        assert(narrationState == .off, "New track must discard old narration state")
        ttsSettings.isEnabled = true
        narrationState = .failed("旧句失败")
        playbackState = .playing
        currentSubtitleIndex = nil
        syncNarration()
        assert(narrationState == .enabled, "Before the first subtitle, stale failure must be cleared")
        ttsSettings.isEnabled = false
        pauseCurrent()
        print("Narration integration checks passed: cutoff cancellation and stale-state reset")
    }

    func prepareDebugPlayback() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wisimi-playback-check.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240000)!
        buffer.frameLength = buffer.frameCapacity
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        let json = """
        [{"type":"audio","title":"晚安 · 轻声陪伴与耳边细语","hash":"debug-a","duration":30,"mediaStreamUrl":"\(url.absoluteString)"},
         {"type":"audio","title":"第二段 · 安静休息","hash":"debug-b","duration":30,"mediaStreamUrl":"\(url.absoluteString)"}]
        """
        queue = try JSONDecoder().decode([TrackNode].self, from: Data(json.utf8))
        workTitle = "播放器验证"
        circleName = "Wisimi"
        ttsSettings.isEnabled = false
        loadCurrent(siblings: queue, autoPlay: false)
    }

    func prepareDebugVideoPlayback() async throws {
        try prepareDebugPlayback()
        let audio = queue[0]
        let url = try await DebugVideoFixture.make()
        let json = """
        [{"type":"other","title":"视频验证 · 完整画面.MP4","hash":"debug-video","duration":8,"mediaDownloadUrl":"\(url.absoluteString)"}]
        """
        let video = try JSONDecoder().decode([TrackNode].self, from: Data(json.utf8))[0]
        queue = [video, audio]
        currentIndex = 0
        loadCurrent(siblings: queue, autoPlay: false)
    }

    func runVideoChecks() async throws {
        try await prepareDebugVideoPlayback()
        let video = currentTrack!
        let originalItem = player.currentItem!
        let context = Self.playbackContext(for: video.id, in: queue)
        assert(context?.queue.map(\.id) == ["debug-video", "debug-a"] && context?.index == 0)
        let asset = originalItem.asset
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        assert(videoTracks.count == 1 && audioTracks.count == 1)
        playCurrent()
        for _ in 0..<50 {
            if playbackState == .playing { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        assert(playbackState == .playing && playbackError == nil)
        let surface = VideoSurfaceView()
        surface.playerLayer.player = videoPlayer
        assert(surface.playerLayer.player === player)
        surface.playerLayer.player = nil
        assert(playbackState.wantsPlayback && player.currentItem === originalItem)
        surface.playerLayer.player = videoPlayer
        assert(player.currentItem === originalItem)
        let subtitle = SubtitleLine(start: 2, end: 4, text: "视频字幕")
        subtitles = [subtitle]
        pauseCurrent()
        seek(to: subtitle)
        syncProgress()
        assert(abs(position - 2) < 0.01, "Pending seek must not revert position on progress sync")
        try await Task.sleep(for: .milliseconds(500))
        assert(abs(position - 2) < 0.6 && currentSubtitle?.text == "视频字幕")
        loadCurrent(siblings: queue, autoPlay: false, resumePosition: 2.5)
        try await Task.sleep(for: .milliseconds(500))
        assert(playbackState == .paused && abs(player.currentTime().seconds - 2.5) < 0.1)
        retryPlayback()
        assert(currentTrack?.id == video.id && playbackError == nil && playbackState.wantsPlayback)
        setSleepTimer(.deadline(.now.addingTimeInterval(0.2)))
        try await Task.sleep(for: .milliseconds(500))
        assert(playbackState == .paused && sleepTimer == .off)
        setSleepTimer(.endOfTrack)
        playCurrent()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.seek(to: CMTime(seconds: 7.8, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
        for _ in 0..<30 {
            if sleepTimer == .off { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        assert(currentIndex == 0 && playbackState == .paused && sleepTimer == .off)
        playCurrent()
        trackDidEnd()
        assert(currentIndex == 1 && currentTrack?.isAudio == true)
        previous()
        assert(currentTrack?.isVideo == true)
        let missing = #"[{"type":"video","title":"missing.mp4","hash":"missing-video","mediaStreamUrl":"file:///wisimi-missing-check.mp4"}]"#
        queue = try JSONDecoder().decode([TrackNode].self, from: Data(missing.utf8))
        currentIndex = 0
        loadCurrent(siblings: queue, autoPlay: true)
        try await Task.sleep(for: .seconds(1))
        assert(playbackError != nil && playbackState == .paused)
        try await prepareDebugVideoPlayback()
        print("MP4 decoding, mixed queue, surface lifecycle, subtitle, retry and sleep timer checks passed")
    }

    func runPlaybackChecks() async throws {
        try prepareDebugPlayback()
        togglePlayback()
        assert(playbackState == .preparing)
        togglePlayback()
        try await Task.sleep(for: .milliseconds(500))
        assert(playbackState == .paused)
        togglePlayback()
        togglePlayback()
        togglePlayback()
        try await Task.sleep(for: .seconds(1))
        assert(playbackState == .playing)
        playbackState = playbackState.receiving(.waiting)
        updateNowPlaying()
        assert(playbackState.wantsPlayback)
        assert(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Int == 0)
        togglePlayback()
        assert(playbackState == .paused)
        playCurrent()
        wasPlayingBeforeInterruption = playbackState.wantsPlayback
        pauseCurrent(preservingInterruption: true)
        assert(wasPlayingBeforeInterruption)
        pauseCurrent()
        assert(!wasPlayingBeforeInterruption)
        failPlayback("验证错误")
        assert(playbackState == .paused && playbackError != nil)
        retryPlayback()
        assert(playbackState.wantsPlayback && playbackError == nil)
        next()
        assert(currentIndex == 1 && playbackState.wantsPlayback)
        next()
        assert(playbackState == .paused)
        setSleepTimer(.deadline(.now.addingTimeInterval(0.2)))
        playCurrent()
        try await Task.sleep(for: .milliseconds(500))
        assert(playbackState == .paused && sleepTimer == .off)
        assert(prefetchTasks.isEmpty && narrationTask == nil)
        setSleepTimer(.deadline(.now.addingTimeInterval(0.2)))
        setSleepTimer(.off)
        playCurrent()
        try await Task.sleep(for: .milliseconds(500))
        assert(playbackState.wantsPlayback)
        setSleepTimer(.endOfTrack)
        let index = currentIndex
        trackDidEnd()
        assert(currentIndex == index && playbackState == .paused && sleepTimer == .off)
        setSleepTimer(.endOfTrack)
        previous()
        assert(sleepTimer == .off)
        setSleepTimer(.deadline(.now.addingTimeInterval(-1)))
        assert(playbackState == .paused && sleepTimer == .off)
        try prepareDebugPlayback()
        currentIndex = 0
        setSleepTimer(.endOfTrack)
        playCurrent()
        try await Task.sleep(for: .milliseconds(500))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.seek(to: CMTime(seconds: 29.9, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
        try await Task.sleep(for: .seconds(1))
        assert(currentIndex == 0 && playbackState == .paused && sleepTimer == .off)
        let missingFile = #"[{"type":"audio","title":"missing","hash":"missing","mediaStreamUrl":"file:///wisimi-missing-check.caf"}]"#
        queue = try JSONDecoder().decode([TrackNode].self, from: Data(missingFile.utf8))
        loadCurrent(siblings: queue, autoPlay: true)
        try await Task.sleep(for: .seconds(1))
        assert(playbackError != nil && playbackState == .paused)
        try prepareDebugPlayback()
        print("Playback and sleep timer integration checks passed")
    }
    #endif
}

private struct PlaybackSnapshot: Codable {
    static let storageKey = "WorkAudioPlayer.playbackSnapshot"

    let workID: Int?
    let localWorkID: UUID?
    let trackID: String
    let position: TimeInterval
    let workTitle: String
    let circleName: String
    let coverURL: String?

    var reference: WorkReference? {
        if let localWorkID { return .local(localWorkID) }
        return workID.map(WorkReference.asmrOne)
    }
}

enum NarrationState: Equatable {
    case off
    case enabled
    case preparing
    case fallback
    case failed(String)
}

#if os(iOS)
private extension AVAudioSessionPortDescription {
    var isDisconnectableAudioOutput: Bool {
        [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones].contains(portType)
    }
}
#endif
