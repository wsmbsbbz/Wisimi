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
    @Published private(set) var playbackState: PlaybackState = .paused
    @Published private(set) var playbackError: String?
    @Published private(set) var sleepTimer: SleepTimer = .off
    private var sleepTimerTask: Task<Void, Never>?
    @Published var subtitles: [SubtitleLine] = []
    @Published var currentSubtitleIndex: Int?
    @Published private(set) var narrationStatuses: [SubtitleLine.ID: TTSGenerationStatus] = [:]

    private let client: ASMRClient
    private let ttsSettings: TTSMixSettings
    private let edgeTTSProvider = EdgeTTSProvider()
    private let openRouterTTSProvider = OpenRouterTTSClient()
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
    private var narrationTask: Task<Void, Never>?
    private var narrationCutoffTask: Task<Void, Never>?
    private var prefetchTasks: [SubtitleLine.ID: Task<Void, Never>] = [:]
    private var artworkTask: Task<Void, Never>?
    private var nowPlayingArtworkURL: URL?
    private var wasPlayingBeforeInterruption = false
    private var isActivatingAudioSession = false
    private var lastSavedPosition: TimeInterval = -1
    private var lastNarrationID: String?
    private var openRouterSession = OpenRouterPlaybackSession()
    private var shownNarrationNotices: Set<String> = []

    init(client: ASMRClient, ttsSettings: TTSMixSettings) {
        self.client = client
        self.ttsSettings = ttsSettings
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        configureAudioSession()
        configureRemoteCommands()
        observeAudioSession()
        narrationPlayer.volume = Float(ttsSettings.volume)
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
                    syncNarration()
                    prefetchUpcomingNarration()
                } else {
                    stopNarration(clearLast: true)
                    cancelPrefetchTasks()
                    narrationStatuses = [:]
                }
            }
            .store(in: &settingsCancellables)
        Publishers.MergeMany(
            ttsSettings.$maxSpeechRate.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            ttsSettings.$model.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            ttsSettings.$voiceID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            ttsSettings.$expressionPreset.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            ttsSettings.$inlineEffectPreset.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] _ in self?.reloadNarrationConfiguration() }
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
            Task { @MainActor in self.syncProgress() }
        }
        Task { await restorePlayback() }
    }

    var videoPlayer: AVPlayer { player }

    var currentTrack: TrackNode? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    var currentSubtitle: SubtitleLine? {
        guard let currentSubtitleIndex, subtitles.indices.contains(currentSubtitleIndex) else { return nil }
        return subtitles[currentSubtitleIndex]
    }

    func play(queue: [TrackNode], start track: TrackNode, siblings: [TrackNode], work: WorkDetail) {
        guard let index = queue.firstIndex(where: { $0.id == track.id }), queue[index].playbackURL != nil else { return }
        if sleepTimer == .endOfTrack { setSleepTimer(.off) }
        self.queue = queue
        self.siblings = siblings
        currentIndex = index
        workID = work.id
        workTitle = work.title
        circleName = work.name
        coverURL = work.mainCoverURL
        resetOpenRouterSession()
        loadCurrent(siblings: siblings, autoPlay: true)
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
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        position = target
        updateSubtitle()
        stopNarration(clearLast: true)
        cancelPrefetchTasks()
        syncNarration()
        updateNowPlaying()
        savePlayback(force: true)
    }

    func seek(to subtitle: SubtitleLine) {
        seek(to: subtitle.start)
    }

    private func loadCurrent(siblings: [TrackNode], autoPlay: Bool, resumePosition: TimeInterval = 0) {
        loadTask?.cancel()
        guard let track = currentTrack, let url = track.playbackURL else { return }

        endObserver.map(NotificationCenter.default.removeObserver)
        failureObserver.map(NotificationCenter.default.removeObserver)
        itemStatusCancellable = nil
        playbackError = nil
        playbackState = autoPlay ? .preparing : .paused
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        stopNarration(clearLast: true)
        cancelPrefetchTasks()
        narrationStatuses = [:]
        position = max(0, min(resumePosition, track.duration ?? resumePosition))
        duration = track.duration ?? 0
        subtitles = []
        currentSubtitleIndex = nil
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
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
        guard !stopIfSleepTimerExpired() else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite, position != seconds {
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

        guard currentTrack == nil else { return }
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
        prefetchTasks[subtitle.id]?.cancel()
        prefetchTasks[subtitle.id] = nil

        let cutoff = narrationCutoff(forSubtitleAt: currentSubtitleIndex)
        narrationStatuses[subtitle.id] = TTSCache.containsValidAudio(at: synthesisRequest.cacheURL) ? .ready : .generating
        narrationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outputURL = try await synthesizeWithFallback(synthesisRequest)
                guard !Task.isCancelled else { return }
                narrationStatuses[subtitle.id] = .ready
                guard ttsSettings.isEnabled,
                      playbackState == .playing,
                      currentNarrationID() == narrationID else { return }
                let item = AVPlayerItem(url: outputURL)
                narrationPlayer.replaceCurrentItem(with: item)
                narrationPlayer.volume = Float(ttsSettings.volume)
                narrationPlayer.play()
                scheduleNarrationCutoff(at: cutoff, narrationID: narrationID)
            } catch {
                guard !Task.isCancelled else { return }
                narrationStatuses[subtitle.id] = .failed
                guard currentNarrationID() == narrationID else { return }
                lastNarrationID = nil
                showNarrationNoticeOnce("旁白生成失败：\(error.localizedDescription)")
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
        let outputURL = synthesisRequest.cacheURL
        if TTSCache.containsValidAudio(at: outputURL) {
            narrationStatuses[subtitle.id] = .ready
            return
        }
        TTSCache.removeIfInvalid(at: outputURL)
        guard prefetchTasks[subtitle.id] == nil else { return }

        narrationStatuses[subtitle.id] = .generating
        prefetchTasks[subtitle.id] = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await synthesizeWithFallback(synthesisRequest)
                guard !Task.isCancelled else { return }
                prefetchTasks[subtitle.id] = nil
                narrationStatuses[subtitle.id] = .ready
            } catch {
                guard !Task.isCancelled else { return }
                prefetchTasks[subtitle.id] = nil
                narrationStatuses[subtitle.id] = .failed
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
        narrationStatuses = Dictionary(uniqueKeysWithValues: subtitles.compactMap { subtitle in
            let text = subtitle.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let url = ttsSettings.synthesisRequest(text: text).cacheURL
            guard TTSCache.containsValidAudio(at: url) else {
                TTSCache.removeIfInvalid(at: url)
                return nil
            }
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
        let request = ttsSettings.synthesisRequest(text: text)
        return "\(currentTrack.id)|\(subtitle.start)|\(TTSCache.fingerprint(for: request))"
    }

    private func reloadNarrationConfiguration() {
        stopNarration(clearLast: true)
        cancelPrefetchTasks()
        refreshCachedNarrationStatuses()
        syncNarration()
        prefetchUpcomingNarration()
    }

    private func resetOpenRouterSession() {
        openRouterSession.reset()
        shownNarrationNotices = []
    }

    private func synthesizeWithFallback(_ request: TTSSynthesisRequest) async throws -> URL {
        if TTSCache.containsValidAudio(at: request.cacheURL) {
            return request.cacheURL
        }
        TTSCache.removeIfInvalid(at: request.cacheURL)
        if request.model == .edge {
            try await edgeTTSProvider.synthesize(request, credential: nil, to: request.cacheURL)
            return request.cacheURL
        }

        guard let token = ttsSettings.openRouterToken(), !token.isEmpty else {
            showNarrationNoticeOnce(TTSSynthesisError.missingCredential.localizedDescription)
            return try await synthesizeWithEdgeFallback(for: request)
        }
        guard !openRouterSession.isCircuitOpen else {
            showNarrationNoticeOnce("OpenRouter 已在本次播放中暂停，旁白将使用 Edge TTS")
            return try await synthesizeWithEdgeFallback(for: request)
        }

        var lastError: Error?
        for attempt in 0..<OpenRouterRetryPolicy.maximumAttempts {
            do {
                try await openRouterTTSProvider.synthesize(request, credential: token, to: request.cacheURL)
                openRouterSession.recordSuccess()
                return request.cacheURL
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TTSSynthesisError {
                lastError = error
                if error.disablesOpenRouterSession {
                    openRouterSession.recordFailure(error)
                    showNarrationNoticeOnce(error.localizedDescription)
                    break
                }
                guard error.isTransient, attempt + 1 < OpenRouterRetryPolicy.maximumAttempts else { break }
            } catch {
                lastError = TTSSynthesisError.transport
                if attempt + 1 == OpenRouterRetryPolicy.maximumAttempts { break }
            }
        }

        if let synthesisError = lastError as? TTSSynthesisError, synthesisError.isTransient {
            openRouterSession.recordFailure(synthesisError)
            if openRouterSession.isCircuitOpen {
                showNarrationNoticeOnce("OpenRouter 连续失败，已在本次播放中暂停并使用 Edge TTS")
            } else {
                showNarrationNoticeOnce(synthesisError.localizedDescription)
            }
        } else if let lastError {
            showNarrationNoticeOnce(lastError.localizedDescription)
        }
        return try await synthesizeWithEdgeFallback(for: request)
    }

    private func synthesizeWithEdgeFallback(for originalRequest: TTSSynthesisRequest) async throws -> URL {
        let fallback = TTSSynthesisRequest(
            model: .edge,
            voiceID: TTSModelID.edge.defaultVoiceID,
            text: originalRequest.text,
            speechRate: originalRequest.speechRate,
            expression: .automatic
        )
        try await edgeTTSProvider.synthesize(fallback, credential: nil, to: fallback.cacheURL)
        return fallback.cacheURL
    }

    private func showNarrationNoticeOnce(_ message: String) {
        guard shownNarrationNotices.insert(message).inserted else { return }
        ttsSettings.runtimeNotice = message
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
