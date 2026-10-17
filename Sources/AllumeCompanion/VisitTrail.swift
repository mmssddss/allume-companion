import Foundation

/// Where the user has been: one entry per board switch Allume's window title reported, with
/// the time it happened (the companion's clock; the CLI has no notion of time). Backs the
/// panel's "最近去过" list, whose rows jump back with `allume open`.
/// Kept at ~/Library/Application Support/AllumeCompanion/trail.json, newest last.
@MainActor
final class VisitTrail {
    struct Visit: Codable, Equatable {
        let boardId: String
        let title: String
        var at: Date
    }

    static let fileURL = BoardIndex.fileURL.deletingLastPathComponent().appendingPathComponent("trail.json")
    static let maxVisits = 200

    private(set) var visits: [Visit] = []

    init() { load() }

    /// The board the window now shows. A switch back to the board we were just on only
    /// refreshes its time, so bouncing between two boards does not flood the list.
    func record(boardId: String, title: String) {
        if let last = visits.last, last.boardId == boardId {
            visits[visits.count - 1].at = Date()
        } else {
            visits.append(Visit(boardId: boardId, title: title, at: Date()))
            if visits.count > Self.maxVisits { visits.removeFirst(visits.count - Self.maxVisits) }
        }
        save()
    }

    /// Distinct boards, most recent first, without `current` (where the user already is).
    func recent(excluding current: String?, limit: Int = 15) -> [Visit] {
        var seen = Set<String>()
        var out: [Visit] = []
        for v in visits.reversed() where v.boardId != current && seen.insert(v.boardId).inserted {
            out.append(v)
            if out.count == limit { break }
        }
        return out
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        visits = (try? dec.decode([Visit].self, from: data)) ?? []
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(visits) { try? data.write(to: Self.fileURL, options: .atomic) }
    }
}

/// "3 分钟前" style relative time for the panel rows.
func relativeTime(_ date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 60 { return String(localized: "刚刚") }
    if s < 3600 { return String(localized: "\(s / 60) 分钟前") }
    if s < 86400 { return String(localized: "\(s / 3600) 小时前") }
    if s < 86400 * 7 { return String(localized: "\(s / 86400) 天前") }
    // "M月d日" in Chinese, "Oct 3" in English: in the language the rest of the UI is in.
    let f = DateFormatter()
    f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f.string(from: date)
}
