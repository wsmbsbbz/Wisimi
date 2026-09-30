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

#if DEBUG
enum PlaybackStateSelfCheck {
    static func run() {
        var state = PlaybackState.paused.receiving(.play)
        assert(state == .preparing && state.wantsPlayback)
        state = state.receiving(.pause).receiving(.outputStarted)
        assert(state == .paused)
        state = state.receiving(.play).receiving(.pause).receiving(.play)
        assert(state.wantsPlayback)
        state = state.receiving(.outputStarted)
        assert(state == .playing)
        assert(state.receiving(.waiting) == .preparing)
        assert(PlaybackState.paused.receiving(.waiting) == .paused)
        for event in [PlaybackState.Event.pause, .activationFailed, .ended, .failed] {
            assert(state.receiving(event) == .paused)
        }
    }
}
#endif
