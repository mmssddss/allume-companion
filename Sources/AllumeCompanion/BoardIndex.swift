import Foundation

/// Title → board document id table for every board in every workspace, so the board title the
/// Allume window reports (the only thing we can read, see AllumeTracker) can be turned into the
/// id `board-content` wants.
///
/// Built by BFS: `list-workspaces` gives each workspace's `rootBoardId`, and
/// `board-content <id> --kinds subBoard --format json` lists the sub-boards mounted on a board
/// (`document.id` is the sub-board's document id). ~80 boards take ~12 s through `open -W`, so
/// the crawl runs in the background with a few boards in flight at once; the result is kept at
/// ~/Library/Application Support/AllumeCompanion/boards.json and loaded first on the next launch.
///
/// Several boards can share a title: all of them are kept, ordered by `lastSeen` (a board we
/// matched a selection against is "seen" again and moves to the front).
@MainActor
final class BoardIndex {
    struct Entry: Codable, Equatable {
        let title: String
        let id: String
        /// Board that lists this one as a sub-board; nil for a workspace root.
        var parentId: String?
        var lastSeen: Date
    }

    private struct File: Codable {
        var version = 1
        var crawledAt: Date?
        var boards: [Entry]
    }

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AllumeCompanion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("boards.json")
    }()

    /// How many `board-content` calls run at once during a crawl.
    nonisolated static let crawlConcurrency = 4
    /// A missed title triggers a new crawl at most this often.
    static let recrawlInterval: TimeInterval = 60

    private(set) var entries: [Entry] = []
    private(set) var crawledAt: Date?
    private var crawl: Task<Void, Never>?
    private var lastCrawlStart: Date?
    /// Called after every crawl that finished (even one that found nothing new).
    var onCrawled: (() -> Void)?

    init() { load() }

    // MARK: - Lookup

    /// Document ids of the boards titled `title`, most recently seen first.
    func lookup(title: String) -> [String] {
        entries.filter { $0.title == title }.sorted { $0.lastSeen > $1.lastSeen }.map(\.id)
    }

    func title(of id: String) -> String? { entries.first { $0.id == id }?.title }

    func parentId(of id: String) -> String? { entries.first { $0.id == id }?.parentId }

    /// Marks `id` as the board we just confirmed the user is on (it wins future ties).
    func touch(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].lastSeen = Date()
        save()
    }

    /// Records a board learned outside the crawl (from `card-content`'s `parentDocumentId`).
    func learn(title: String, id: String) {
        guard !title.isEmpty, !entries.contains(where: { $0.id == id }) else { touch(id); return }
        entries.append(Entry(title: title, id: id, parentId: nil, lastSeen: Date()))
        Log.info("board index: learned \"\(title)\" = \(id)")
        save()
    }

    var isCrawling: Bool { crawl != nil }

    // MARK: - Crawl

    /// Starts a background crawl unless one is running. With `throttled`, nothing happens if a
    /// crawl started less than `recrawlInterval` ago (for "title not found" retries).
    @discardableResult
    func refresh(reason: String, throttled: Bool = false) -> Bool {
        if crawl != nil { return false }
        if throttled, let t = lastCrawlStart, Date().timeIntervalSince(t) < Self.recrawlInterval {
            Log.info("board index: not recrawling (\(reason)); last crawl \(Int(Date().timeIntervalSince(t))) s ago")
            return false
        }
        lastCrawlStart = Date()
        Log.info("board index: crawl started (\(reason))")
        crawl = Task { [weak self] in
            let t0 = Date()
            let (found, calls) = await Self.crawlAll()
            guard let self else { return }
            self.crawl = nil
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            guard !found.isEmpty else {
                Log.info("board index: crawl found nothing (\(calls) CLI calls, \(ms) ms); keeping \(self.entries.count) cached boards")
                self.onCrawled?()
                return
            }
            self.merge(found)
            self.crawledAt = Date()
            self.save()
            let dup = Dictionary(grouping: self.entries, by: \.title).filter { $0.value.count > 1 }.count
            Log.info("board index: \(self.entries.count) boards (\(dup) titles shared), \(calls) CLI calls, \(ms) ms")
            self.onCrawled?()
        }
        return true
    }

    /// Keeps `lastSeen` of boards we already knew, drops boards the crawl no longer finds.
    private func merge(_ found: [Entry]) {
        let old = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        entries = found.map { e in
            var e = e
            if let o = old[e.id] { e.lastSeen = max(o.lastSeen, e.lastSeen) }
            return e
        }
    }

    private struct Workspace: Decodable { let title: String?; let rootBoardId: String? }
    private struct SubBoardRow: Decodable {
        struct Document: Decodable { let id: String?; let title: String? }
        let title: String?
        let document: Document?
    }

    /// BFS over every workspace. Returns the boards found and the number of CLI calls made.
    nonisolated private static func crawlAll() async -> ([Entry], Int) {
        var calls = 1
        let ws = await AllumeCLI.run(["list-workspaces", "--format", "json"], background: true)
        guard ws.ok, let workspaces = try? JSONDecoder().decode([Workspace].self, from: Data(ws.stdout.utf8)) else {
            Log.info("board index: list-workspaces failed: \(ws.stderr.split(separator: "\n").first ?? "")")
            return ([], calls)
        }
        let seen = Date(timeIntervalSince1970: 0) // "never confirmed"; merge keeps real values
        var found: [Entry] = []
        var visited = Set<String>()
        var frontier: [String] = []
        for w in workspaces {
            guard let root = w.rootBoardId, visited.insert(root).inserted else { continue }
            found.append(Entry(title: w.title ?? "", id: root, parentId: nil, lastSeen: seen))
            frontier.append(root)
        }
        while !frontier.isEmpty {
            var next: [Entry] = []
            for chunk in stride(from: 0, to: frontier.count, by: crawlConcurrency) {
                let ids = Array(frontier[chunk..<min(chunk + crawlConcurrency, frontier.count)])
                calls += ids.count // AllumeCLI's own retries not counted; they are rare
                let rows = await withTaskGroup(of: (String, [SubBoardRow]).self) { group in
                    for id in ids {
                        group.addTask {
                            let args = ["board-content", id, "--kinds", "subBoard", "--format", "json"]
                            // (AllumeCLI.run itself retries the occasional `open -W` attach failure.)
                            let r = await AllumeCLI.run(args, background: true)
                            let rows = r.ok ? ((try? JSONDecoder().decode([SubBoardRow].self, from: Data(r.stdout.utf8))) ?? []) : []
                            if !r.ok { Log.info("board index: board-content \(id) failed: \(r.stderr.split(separator: "\n").first ?? "")") }
                            return (id, rows)
                        }
                    }
                    var out: [(String, [SubBoardRow])] = []
                    for await x in group { out.append(x) }
                    return out
                }
                for (parent, subRows) in rows {
                    for row in subRows {
                        guard let id = row.document?.id, visited.insert(id).inserted else { continue }
                        next.append(Entry(title: row.document?.title ?? row.title ?? "", id: id, parentId: parent, lastSeen: seen))
                    }
                }
            }
            found += next
            frontier = next.map(\.id)
        }
        return (found, calls)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let file = try? dec.decode(File.self, from: data) else {
            Log.info("board index: \(Self.fileURL.path) unreadable; ignoring")
            return
        }
        entries = file.boards
        crawledAt = file.crawledAt
        Log.info("board index: loaded \(entries.count) boards from cache (crawled \(file.crawledAt.map { "\($0)" } ?? "never"))")
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(File(crawledAt: crawledAt, boards: entries)) else { return }
        do { try data.write(to: Self.fileURL, options: .atomic) }
        catch { Log.info("board index: save failed: \(error.localizedDescription)") }
    }
}
