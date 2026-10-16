import Foundation

/// One `@todo` card anywhere in the workspace, as the panel's "全部待办" list shows it.
struct TodoItem: Codable, Hashable, Identifiable {
    let cardId: String
    let documentId: String?
    let boardId: String
    let boardTitle: String
    let title: String
    let body: String
    /// First `YYYY-MM-DD`-like date in the body (`截止 2026-10-20`, `2026/10/20`, `10月20日`), as a day.
    let due: Date?

    var id: String { cardId }

    /// What the row is called: the card title, else the first body line that is not the marker
    /// or a date/time stamp.
    var label: String {
        if !title.isEmpty { return title }
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let dateLike = try! NSRegularExpression(pattern: #"^(截止|due)?\s*[\d]{4}[-/.年]\d{1,2}[-/.月]\d{1,2}"#, options: .caseInsensitive)
        for l in lines.dropFirst() where !l.isEmpty {
            if dateLike.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil { continue }
            return String(l.prefix(60))
        }
        return "（无标题）"
    }

    /// Days from today to the due day: negative = overdue, 0 = today, nil = no date.
    func daysLeft(now: Date = Date()) -> Int? {
        guard let due else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: due)).day
    }

    var dueLabel: String? {
        guard let d = daysLeft() else { return nil }
        if d < 0 { return "已过期 \(-d) 天" }
        if d == 0 { return "今天" }
        if d == 1 { return "明天" }
        return "\(d) 天后"
    }
}

/// Every `@todo` text card in every board, found with one
/// `board-content <id> --filter @todo --kinds text --format json` per board of the BoardIndex
/// (a few in flight at once, all background). A card counts when the first line of its body is
/// exactly `@todo` (the skill's convention: the marker lives in the body, since the CLI cannot
/// edit titles). Refreshed after every index crawl, then every `interval` while Allume runs;
/// in between, a board the BoardModel just loaded updates its own slice for free (`adopt`).
/// Cached at ~/Library/Application Support/AllumeCompanion/todos.json so the list is there at launch.
@MainActor
final class TodoIndex {
    static let fileURL = BoardIndex.fileURL.deletingLastPathComponent().appendingPathComponent("todos.json")
    static let interval: TimeInterval = 15 * 60
    nonisolated static let concurrency = 4

    private(set) var items: [TodoItem] = []
    private(set) var scannedAt: Date?
    private var scan: Task<Void, Never>?
    /// Called on the main actor whenever `items` changed (the panel re-sorts, reminders reschedule).
    var onChanged: (() -> Void)?

    init() { load() }

    var isScanning: Bool { scan != nil }

    /// Overdue first (most overdue on top), then by due day, then undated grouped by board.
    var sorted: [TodoItem] {
        items.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return x != y ? x < y : a.cardId < b.cardId
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.boardTitle != b.boardTitle ? a.boardTitle < b.boardTitle : a.cardId < b.cardId
            }
        }
    }

    var overdueCount: Int { items.filter { ($0.daysLeft() ?? 1) <= 0 }.count }

    // MARK: - Parsing

    /// `@todo` on the first non-empty line, alone (the convention) — `@todo 打电话` on one line
    /// is accepted too, so a hastily typed card still counts.
    nonisolated static func isTodo(_ body: String?) -> Bool {
        guard let first = body?.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        let t = first.trimmingCharacters(in: .whitespaces).lowercased()
        return t == "@todo" || t.hasPrefix("@todo ")
    }

    nonisolated private static let fullDate = try! NSRegularExpression(pattern: #"(20\d\d)\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})"#)
    nonisolated private static let monthDay = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})\s*月\s*(\d{1,2})\s*(日|号)"#)

    /// First date in `body`. `10月20日` without a year is this year, or next year if that day
    /// is more than a month past (a due date rarely points far back).
    nonisolated static func dueDate(in body: String, now: Date = Date()) -> Date? {
        let ns = body as NSString
        let range = NSRange(location: 0, length: ns.length)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        if let m = fullDate.firstMatch(in: body, range: range) {
            let y = Int(ns.substring(with: m.range(at: 1))), mo = Int(ns.substring(with: m.range(at: 2))), d = Int(ns.substring(with: m.range(at: 3)))
            return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: 9))
        }
        if let m = monthDay.firstMatch(in: body, range: range) {
            let mo = Int(ns.substring(with: m.range(at: 1))), d = Int(ns.substring(with: m.range(at: 2)))
            let year = cal.component(.year, from: now)
            guard let thisYear = cal.date(from: DateComponents(year: year, month: mo, day: d, hour: 9)) else { return nil }
            if thisYear.timeIntervalSince(now) < -30 * 86400 {
                return cal.date(from: DateComponents(year: year + 1, month: mo, day: d, hour: 9))
            }
            return thisYear
        }
        return nil
    }

    nonisolated static func items(from rows: [BoardCard], boardId: String, boardTitle: String) -> [TodoItem] {
        rows.compactMap { row in
            guard row.kind == "text", let body = row.document?.body, isTodo(body) else { return nil }
            return TodoItem(cardId: row.id, documentId: row.document?.id, boardId: boardId, boardTitle: boardTitle,
                            title: row.title ?? "", body: body, due: dueDate(in: body))
        }
    }

    // MARK: - Updating

    /// Rows of one board someone just read in full (BoardModel): replace that board's slice.
    func adopt(boardId: String, boardTitle: String, rows: [BoardCard]) {
        let fresh = Self.items(from: rows, boardId: boardId, boardTitle: boardTitle)
        let others = items.filter { $0.boardId != boardId }
        let next = others + fresh
        guard Set(next) != Set(items) else { return }
        items = next
        Log.info("todo index: \"\(boardTitle)\" now has \(fresh.count) @todo (from board model); \(items.count) total")
        save()
        onChanged?()
    }

    /// Scans every board of `index` in the background; one scan at a time.
    func refresh(index: BoardIndex, reason: String) {
        guard scan == nil else { return }
        let boards = index.entries.map { ($0.id, $0.title) }
        guard !boards.isEmpty else { return }
        Log.info("todo index: scan started (\(reason)), \(boards.count) boards")
        scan = Task { [weak self] in
            let t0 = Date()
            let (found, failed) = await Self.scanAll(boards)
            guard let self else { return }
            self.scan = nil
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if failed == boards.count {
                Log.info("todo index: every board-content failed (\(ms) ms); keeping \(self.items.count) cached items")
                return
            }
            // Boards whose read failed keep their old slice.
            let failedIds = Set(found.failedBoardIds)
            let kept = self.items.filter { failedIds.contains($0.boardId) }
            let next = kept + found.items
            let changed = Set(next) != Set(self.items)
            self.items = next
            self.scannedAt = Date()
            self.save()
            Log.info("todo index: \(self.items.count) @todo across \(boards.count) boards (\(failed) reads failed), \(ms) ms\(changed ? "" : ", unchanged")")
            if changed { self.onChanged?() }
        }
    }

    private struct Found { var items: [TodoItem] = []; var failedBoardIds: [String] = [] }

    nonisolated private static func scanAll(_ boards: [(String, String)]) async -> (Found, Int) {
        var found = Found()
        for chunk in stride(from: 0, to: boards.count, by: concurrency) {
            let slice = Array(boards[chunk..<min(chunk + concurrency, boards.count)])
            let results = await withTaskGroup(of: (String, String, [BoardCard]?).self) { group in
                for (id, title) in slice {
                    group.addTask {
                        let r = await AllumeCLI.run(["board-content", id, "--filter", "@todo", "--kinds", "text", "--format", "json"], background: true)
                        return (id, title, r.ok ? BoardCard.decodeRows(r.stdout) : nil)
                    }
                }
                var out: [(String, String, [BoardCard]?)] = []
                for await x in group { out.append(x) }
                return out
            }
            for (id, title, rows) in results {
                guard let rows else { found.failedBoardIds.append(id); continue }
                found.items += items(from: rows, boardId: id, boardTitle: title)
            }
        }
        return (found, found.failedBoardIds.count)
    }

    // MARK: - Persistence

    private struct File: Codable { var scannedAt: Date?; var items: [TodoItem] }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let f = try? dec.decode(File.self, from: data) else { return }
        items = f.items; scannedAt = f.scannedAt
        Log.info("todo index: loaded \(items.count) items from cache")
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(File(scannedAt: scannedAt, items: items)) { try? data.write(to: Self.fileURL, options: .atomic) }
    }
}
