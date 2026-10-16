import Foundation

/// One `board-content` / `card-content` row; only the fields we use.
struct BoardCard: Decodable {
    struct Frame: Decodable, Equatable {
        let x: Double, y: Double, width: Double, height: Double
    }
    struct Document: Decodable {
        let id: String?
        let body: String?       // text / chain cards: the inline body
    }
    let id: String
    let kind: String?
    let title: String?
    let createdAt: String?      // ISO-8601 with Z, so string order is time order
    let frame: Frame
    let parentDocumentId: String?
    let document: Document?

    static func decodeRows(_ json: String) -> [BoardCard] {
        (try? JSONDecoder().decode([BoardCard].self, from: Data(json.utf8))) ?? []
    }
}

/// In-memory copy of the board the user is looking at: every card's id, kind, title, frame,
/// creation time and document id, from one `board-content --format json`.
///
/// Which board: AllumeTracker reports the window title, BoardIndex turns it into a document id.
/// When: the title changes, the panel opens, a write command finished, and every
/// `periodicInterval` while Allume is frontmost. Allume sends no change notifications, so the
/// data is at most that stale; `age` says how stale, and callers that must not be wrong (the
/// undo snapshot) only trust it when it is younger than `CommandRunner.snapshotMaxAge`.
///
/// After each load the thumbnails of the first `prewarmCount` cards (reading order) are fetched
/// in the background into the shared ThumbnailLoader cache, so ⌘K on them shows pictures at once.
@MainActor
final class BoardModel {
    static let periodicInterval: TimeInterval = 10
    static let prewarmCount = 12

    let index: BoardIndex
    let thumbnails: ThumbnailLoader

    /// Title Allume's window last reported (may be unresolved: see `boardId`).
    private(set) var title = ""
    /// Document id of the board the model holds, nil until the title resolved.
    private(set) var boardId: String?
    private(set) var cards: [String: BoardCard] = [:]
    /// Rows in the order `board-content` returned them.
    private(set) var rows: [BoardCard] = []
    private(set) var loadedAt: Date?
    /// Whether Allume is frontmost; the periodic refresh only runs while it is.
    var allumeActive = false
    /// Called on the main actor after every successful load (the panel re-reads titles from it).
    var onLoaded: (() -> Void)?

    private var inFlight: Task<Void, Never>?
    private var prewarm: Task<Void, Never>?
    private var timer: Timer?

    init(index: BoardIndex, thumbnails: ThumbnailLoader) {
        self.index = index
        self.thumbnails = thumbnails
        index.onCrawled = { [weak self] in self?.resolveAfterCrawl() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.periodicInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.allumeActive, self.boardId != nil else { return }
                await self.refresh(reason: "periodic")
            }
        }
    }

    /// Seconds since the last load; nil when nothing is loaded.
    var age: TimeInterval? { loadedAt.map { Date().timeIntervalSince($0) } }

    func isFresh(within seconds: TimeInterval) -> Bool { age.map { $0 <= seconds } ?? false }

    /// Scope prefix (`<prefix>:`) shared by the board's document id and its cards' ids.
    var scopePrefix: String? { boardId.map { String($0.prefix { $0 != ":" }) } }

    /// True when every id belongs to the loaded board's scope (not when it is in `cards`:
    /// a card created after the last load is on the board but not in the model yet).
    func card(_ id: String) -> BoardCard? { cards[id] }

    // MARK: - Which board

    /// The window title changed (or was first seen). Resolves it through the index and loads
    /// the board when it is a different one; an unknown title asks the index for a recrawl.
    func setTitle(_ newTitle: String) {
        guard !newTitle.isEmpty, newTitle != title else { return }
        title = newTitle
        resolve(reason: "title changed")
    }

    private func resolve(reason: String) {
        let candidates = index.lookup(title: title)
        guard let id = candidates.first else {
            if boardId != nil { Log.info("board model: \"\(title)\" not in index; keeping \(boardId!) until it resolves") }
            else { Log.info("board model: \"\(title)\" not in index") }
            boardId = nil; cards = [:]; rows = []; loadedAt = nil
            index.refresh(reason: "title \"\(title)\" unknown", throttled: true)
            return
        }
        if candidates.count > 1 {
            Log.info("board model: \"\(title)\" has \(candidates.count) boards; taking the most recently seen")
        }
        switchTo(id, reason: reason)
    }

    private func resolveAfterCrawl() {
        guard boardId == nil, !title.isEmpty else { return }
        resolve(reason: "index crawled")
    }

    private func switchTo(_ id: String, reason: String) {
        guard id != boardId else { return }
        boardId = id
        cards = [:]; rows = []; loadedAt = nil
        prewarm?.cancel(); prewarm = nil
        Log.info("board model: \"\(title)\" → \(id) (\(reason))")
        Task { await refresh(reason: reason) }
    }

    /// A selection came in from Allume. If its cards' scope is not the loaded board's but is
    /// another board with the same title, that is the one the user is on: switch to it. With
    /// `parentDocumentId` (learned from `card-content`) an unresolved title is settled outright.
    func noteSelection(ids: [String], parentDocumentId: String? = nil) {
        let scopes = Set(ids.map { String($0.prefix { $0 != ":" }) })
        guard scopes.count == 1, let scope = scopes.first else { return }
        if let boardId, boardId.hasPrefix(scope + ":") {
            index.touch(boardId)
            return
        }
        if let parentDocumentId, parentDocumentId.hasPrefix(scope + ":") {
            index.learn(title: title, id: parentDocumentId)
            switchTo(parentDocumentId, reason: "selection's parent board")
            return
        }
        if let other = index.lookup(title: title).first(where: { $0.hasPrefix(scope + ":") }) {
            index.touch(other)
            switchTo(other, reason: "selection scope matches another \"\(title)\"")
        }
    }

    // MARK: - Loading

    /// Loads the board with one `board-content`; concurrent calls share the load in flight.
    func refresh(reason: String) async {
        if let inFlight { await inFlight.value; return }
        guard let id = boardId else { return }
        let task = Task { await self.load(id, reason: reason) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func load(_ id: String, reason: String) async {
        let t0 = Date()
        let r = await AllumeCLI.run(["board-content", id, "--format", "json"], background: true)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        guard boardId == id else { return } // switched meanwhile
        guard r.ok else {
            Log.info("board model: board-content \(id) failed (\(reason)): \(r.stderr.split(separator: "\n").first ?? "")")
            return
        }
        let loaded = BoardCard.decodeRows(r.stdout)
        rows = loaded
        cards = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        loadedAt = Date()
        Log.info("board model: \"\(title)\" loaded \(loaded.count) cards (\(reason), \(ms) ms)")
        onLoaded?()
        startPrewarm()
    }

    private func startPrewarm() {
        prewarm?.cancel()
        let first = rows
            .sorted { a, b in abs(a.frame.y - b.frame.y) > 1 ? a.frame.y < b.frame.y : a.frame.x < b.frame.x }
            .prefix(Self.prewarmCount)
            .filter { ThumbnailLoader.hasThumbnail(kind: $0.kind ?? "") && thumbnails.cached($0.id) == nil }
            .map { CardSummary(id: $0.id, title: $0.title ?? "", kind: $0.kind ?? "", documentId: $0.document?.id) }
        guard !first.isEmpty else { return }
        let boardTitle = title
        prewarm = Task { [thumbnails] in
            var done = 0
            // Two at a time: enough to overlap the ~150 ms process launches, not enough to
            // crowd out a ⌘K that arrives meanwhile.
            for pair in stride(from: 0, to: first.count, by: 2) {
                if Task.isCancelled { break }
                let batch = first[pair..<min(pair + 2, first.count)]
                await withTaskGroup(of: Void.self) { group in
                    for card in batch { group.addTask { _ = await thumbnails.thumbnail(for: card, background: true) } }
                }
                done += batch.count
            }
            if !Task.isCancelled { Log.info("board model: prewarmed \(done) thumbnails on \"\(boardTitle)\"") }
        }
    }
}
