import Foundation

enum SleepTimer: Equatable {
    case off
    case deadline(Date)
    case endOfTrack

    func hasExpired(at now: Date = .now) -> Bool {
        if case .deadline(let deadline) = self { return now >= deadline }
        return false
    }
}

#if DEBUG
enum SleepTimerSelfCheck {
    static func run() {
        let deadline = Date(timeIntervalSince1970: 100)
        let timer = SleepTimer.deadline(deadline)
        assert(!timer.hasExpired(at: deadline.addingTimeInterval(-1)))
        assert(timer.hasExpired(at: deadline))
        assert(timer.hasExpired(at: deadline.addingTimeInterval(1)))
        assert(!SleepTimer.off.hasExpired(at: deadline))
        assert(!SleepTimer.endOfTrack.hasExpired(at: deadline))
    }
}
#endif
