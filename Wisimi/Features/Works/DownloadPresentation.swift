import Foundation

struct DownloadSummary {
    let entries: [DownloadEntry]
    func count(_ state: DownloadEntry.State) -> Int { entries.count { $0.state == state } }
    var total: Int { entries.count }
    var completed: Int { count(.completed) }
    var hasUnfinished: Bool { completed < entries.count }
    var completionText: String { "已下载 \(completed)/\(entries.count) 个文件" }
    var unfinishedWorkCount: Int {
        Set(entries.filter { $0.state != .completed }.map(\.localWorkID)).count
    }
    var statusText: String {
        [(DownloadEntry.State.downloading, "下载中"), (.paused, "已暂停"), (.failed, "失败")]
            .compactMap { state, title in
                let count = count(state)
                return count > 0 ? "\(count) 个\(title)" : nil
            }.joined(separator: " · ")
    }
    var cardBadgeText: String? {
        guard hasUnfinished else { return nil }
        if count(.downloading) > 0 { return "下载中 \(completed)/\(entries.count)" }
        if count(.failed) > 0 { return "\(count(.failed)) 个失败" }
        return "已暂停 \(completed)/\(entries.count)"
    }
    var cardBadgeSymbol: String {
        if count(.downloading) > 0 { return "arrow.down.circle" }
        if count(.failed) > 0 { return "exclamationmark.circle" }
        return "pause.circle"
    }
    var progress: Double? {
        guard !entries.isEmpty, entries.allSatisfy({ $0.expected > 0 }) else { return nil }
        let total = entries.reduce(0.0) { $0 + Double($1.expected) }
        let received = entries.reduce(0.0) { $0 + Double(min(max($1.received, 0), $1.expected)) }
        return received / total
    }
}

extension DownloadStore {
    func summary(forLocalWork id: UUID) -> DownloadSummary? {
        let workEntries = entries(forLocalWork: id)
        return workEntries.isEmpty ? nil : DownloadSummary(entries: workEntries)
    }
}

extension DownloadEntry {
    var displayStatus: String { state == .downloading && received == 0 ? "等待传输" : state.title }
    var sizeText: String {
        let receivedText = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard state != .completed, expected > 0 else { return receivedText }
        return receivedText + " / " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
    }
}
