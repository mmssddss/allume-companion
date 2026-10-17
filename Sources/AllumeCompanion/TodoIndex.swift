import Foundation

/// One `@todo` card anywhere in the workspace, as the panel's "全部待办" list shows it.
struct TodoItem: Codable, Hashable, Identifiable {
    let cardId: String
    let documentId: String?
    let boardId: String
    let boardTitle: String
    let title: String
    let body: String
    /// The day named by the marker line, `@todo(due: 2026-10-20)`; nil for a plain `@todo`.
    let due: Date?

    var id: String { cardId }

    /// What the row is called: the card title, else what follows the marker on its line
    /// (`@todo(due: 2026-10-20) 交房租`), else the first non-empty body line after it.
    var label: String {
        if !title.isEmpty { return title }
        if let c = TodoIndex.context(in: body) { return String(c.prefix(60)) }
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for l in lines.dropFirst() where !l.isEmpty { return String(l.prefix(60)) }
        return String(localized: "（无标题）")
    }

    /// Days from today to the due day: negative = overdue, 0 = today, nil = no date.
    func daysLeft(now: Date = Date()) -> Int? {
        guard let due else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: due)).day
    }

    var dueLabel: String? {
        guard let d = daysLeft() else { return nil }
        if d < 0 { return String(localized: "已过期 \(-d) 天") }
        if d == 0 { return String(localized: "今天") }
        if d == 1 { return String(localized: "明天") }
        return String(localized: "\(d) 天后")
    }
}

/// Every `@todo` text card in every board, found with one
/// `board-content <id> --filter @todo --kinds text --format json` per board of the BoardIndex
/// (a few in flight at once, all background). A card counts when the first line of its body is
/// `@todo` or `@todo(due: YYYY-MM-DD)` (the skill's convention: the marker lives in the body,
/// since the CLI cannot edit titles; the due day lives in the marker, not loose in the text). Refreshed after every index crawl, then every `interval` while Allume runs;
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

    /// The marker line: `@todo`, or `@todo(due: 2026-10-20)` for a dated one. Whitespace inside
    /// the parentheses is free, trailing words after the marker are tolerated, case is ignored.
    nonisolated private static let marker = try! NSRegularExpression(
        pattern: #"^@todo(?:\s*\(\s*due\s*:\s*(\d{4})-(\d{1,2})-(\d{1,2})\s*\))?(?:\s|$)"#, options: .caseInsensitive)

    nonisolated private static func markerMatch(_ body: String?) -> (line: NSString, match: NSTextCheckingResult)? {
        guard let first = body?.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let line = first.trimmingCharacters(in: .whitespaces) as NSString
        guard let m = marker.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) else { return nil }
        return (line, m)
    }

    /// The words after the marker on its own line, nil when there are none.
    nonisolated static func context(in body: String) -> String? {
        guard let (line, m) = markerMatch(body) else { return nil }
        let rest = line.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// A card is a todo when the first non-empty line of its body starts with the `@todo` marker.
    nonisolated static func isTodo(_ body: String?) -> Bool { markerMatch(body) != nil }

    /// The due day of the marker line, at 09:00 local time; nil when the marker has no `(due: …)`.
    nonisolated static func dueDate(in body: String) -> Date? {
        guard let (line, m) = markerMatch(body), m.range(at: 1).location != NSNotFound else { return nil }
        let y = Int(line.substring(with: m.range(at: 1))), mo = Int(line.substring(with: m.range(at: 2))), d = Int(line.substring(with: m.range(at: 3)))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: 9))
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
        // Empty boards (most daily notes) hold no todo: no call for them.
        let boards = index.entries.filter { $0.cardCount != 0 }.map { ($0.id, $0.title) }
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

/// What the panel's "添加待办" field becomes: one marker line, `@todo(due: 2026-10-20) 交房租`
/// or `@todo 交房租`, the same shape `TodoIndex` reads back (`dueDate`, `context`). The due day
/// is a date phrase at either end of the text (`DateWords`: `下周二`, `明天`, `10-20`, …).
struct TodoDraft: Equatable {
    var text: String
    /// `YYYY-MM-DD`, nil for an undated todo.
    var due: String?

    var body: String { (due.map { "@todo(due: \($0))" } ?? "@todo") + (text.isEmpty ? "" : " " + text) }

    nonisolated static func parse(_ raw: String, today: Date = Date()) -> TodoDraft {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for atEnd in [true, false] {
            guard let m = DateWords.match(in: text, atEnd: atEnd, today: today) else { continue }
            var rest = text
            rest.removeSubrange(m.range)
            return TodoDraft(text: rest.trimmingCharacters(in: .whitespaces), due: DateWords.iso(m.date))
        }
        return TodoDraft(text: text)
    }
}
