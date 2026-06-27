import Foundation

extension Optional where Wrapped == Double {
    var formattedDuration: String {
        guard let self else { return "-" }
        let totalSeconds = Int(self.rounded())
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m \(seconds)s"
    }
}
