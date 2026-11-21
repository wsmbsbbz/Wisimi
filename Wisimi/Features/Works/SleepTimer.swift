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


