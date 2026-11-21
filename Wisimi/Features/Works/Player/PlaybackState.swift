enum PlaybackState: Equatable {
    case paused, preparing, playing

    var wantsPlayback: Bool { self != .paused }

    enum Event {
        case play, pause, outputStarted, waiting, activationFailed, ended, failed
    }

    func receiving(_ event: Event) -> Self {
        switch event {
        case .play: .preparing
        case .pause, .activationFailed, .ended, .failed: .paused
        case .outputStarted: wantsPlayback ? .playing : .paused
        case .waiting: wantsPlayback ? .preparing : .paused
        }
    }
}


