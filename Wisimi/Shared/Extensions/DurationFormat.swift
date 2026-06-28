import Foundation

extension Double {
    var formattedDuration: String {
        guard isFinite else { return "0m 0s" }
        let totalSeconds = Int(rounded())
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m \(seconds)s"
    }
}

extension Optional where Wrapped == Double {
    var formattedDuration: String {
        self?.formattedDuration ?? "-"
    }
}
