import Foundation

enum DownloadFilter: String, CaseIterable, Identifiable {
    case all = "全部", unfinished = "未完成", completed = "已下载"
    var id: Self { self }
    func includes(_ entry: DownloadEntry) -> Bool {
        switch self {
        case .all: true
        case .unfinished: entry.state != .completed
        case .completed: entry.state == .completed
        }
    }
}

struct DownloadSummary {
    let entries: [DownloadEntry]
    func count(_ state: DownloadEntry.State) -> Int { entries.count { $0.state == state } }
    var completed: Int { count(.completed) }
    var hasUnfinished: Bool { completed < entries.count }
    var completionText: String { "已下载 \(completed)/\(entries.count) 个所选文件" }
    var statusText: String {
        [(DownloadEntry.State.downloading, "下载中"), (.paused, "暂停"), (.failed, "失败")]
            .compactMap { state, title in
                let count = count(state)
                return count > 0 ? "\(count) 个\(title)" : nil
            }.joined(separator: " · ")
    }
    var progress: Double? {
        guard !entries.isEmpty, entries.allSatisfy({ $0.expected > 0 }) else { return nil }
        let total = entries.reduce(0.0) { $0 + Double($1.expected) }
        let received = entries.reduce(0.0) { $0 + Double(min(max($1.received, 0), $1.expected)) }
        return received / total
    }
}

struct DownloadWorkGroup: Identifiable {
    let saved: DownloadedWork
    let entries: [DownloadEntry]
    let visibleEntries: [DownloadEntry]
    var id: Int { saved.id }
    var summary: DownloadSummary { DownloadSummary(entries: entries) }

    static func make(works: [DownloadedWork], entries: [DownloadEntry], filter: DownloadFilter) -> [Self] {
        let grouped = Dictionary(grouping: entries, by: \.workID)
        return works.compactMap { saved in
            let files = grouped[saved.id] ?? []
            let visible = files.filter(filter.includes)
            return visible.isEmpty ? nil : Self(saved: saved, entries: files, visibleEntries: visible)
        }.sorted {
            if $0.summary.hasUnfinished != $1.summary.hasUnfinished { return $0.summary.hasUnfinished }
            return $0.id > $1.id
        }
    }
}

extension DownloadEntry {
    var displayStatus: String { state == .downloading && received == 0 ? "等待传输" : state.title }
    var fileSymbol: String {
        if track.isVideo { return "film" }
        if track.isAudio { return "waveform" }
        if track.isSubtitle { return "captions.bubble" }
        if track.isImage { return "photo" }
        return "doc"
    }
    var sizeText: String {
        let receivedText = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard state != .completed, expected > 0 else { return receivedText }
        return receivedText + " / " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
    }
}
