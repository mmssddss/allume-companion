import Foundation

/// The panel commands, each a thin wrapper over the CLI, plus a one-level undo. Deleting is
/// deliberately not offered: Allume's own Delete key does that, with its own ⌘Z.
/// Output is appended to `state.log`.
///
/// Undo: Allume's own ⌘Z cannot revert what the CLI does (the CLI goes through Allume's helper
/// pipeline, not its undo manager), so before every command we record what is needed to reverse
/// it ourselves: gathering and resizing record each card's current frame via
/// `board-content --format json` (undo = `card-move` back). Only the
/// most recent step is kept, and undoing is itself not undoable.
@MainActor
final class CommandRunner {
    let state: AppState
    /// Previews for the card stack, cached by card id.
    let thumbnails = ThumbnailLoader()
    init(state: AppState) { self.state = state }

    // MARK: - Undo state

    private struct Frame: Decodable, Equatable {
        let x: Double, y: Double, width: Double, height: Double
    }

    /// One `board-content` / `card-content` row; only the fields we need.
    private struct CardRow: Decodable {
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
    }

    /// Rows cached by the last `fetchRows`, so `gather` can sort by title/createdAt without
    /// a second round of CLI calls.
    private var lastRows: [String: CardRow] = [:]

    private struct UndoEntry {
        let label: String
        /// CLI invocations that reverse the step, run in order.
        let commands: [[String]]
    }

    private var undoEntry: UndoEntry? {
        didSet { state.undoLabel = undoEntry?.label }
    }

    /// Cache: card-id scope prefix → parent board document id. The scope prefix of a card id is
    /// also the prefix of its board's document id, but the suffix differs and `board-content`
    /// rejects anything but the full document id, so we learn it once from `card-content`.
    private var boardIdByScope: [String: String] = [:]

    // MARK: - CLI

    @discardableResult
    private func exec(_ args: [String], showStdout: Bool = true) async -> AllumeCLI.Result {
        state.appendLog(AllumeCLI.render(args))
        let r = await AllumeCLI.run(args)
        if showStdout, !r.stdout.isEmpty { state.appendLog(r.stdout) }
        if !r.stderr.isEmpty { state.appendLog("stderr: " + r.stderr) }
        if !r.ok {
            state.appendLog("exit \(r.status)")
            state.status = r.stderr.split(separator: "\n").first.map(String.init) ?? "命令失败（exit \(r.status)）"
        }
        return r
    }

    private func guarded(_ body: () async -> Void) async {
        guard !state.isRunning else { return }
        guard !state.selectedCardIds.isEmpty else { state.appendLog("没有选中的卡片。先按 ⌘K 读取。"); return }
        state.isRunning = true
        state.status = ""
        await body()
        state.isRunning = false
    }

    // MARK: - Frame snapshot

    private func decodeRows(_ json: String) -> [CardRow] {
        (try? JSONDecoder().decode([CardRow].self, from: Data(json.utf8))) ?? []
    }

    private func readCard(_ id: String) async -> CardRow? {
        let r = await exec(["card-content", id, "--format", "json"], showStdout: false)
        return r.ok ? decodeRows(r.stdout).first : nil
    }

    /// Current frames of `ids` (see `fetchRows`).
    private func snapshotFrames(_ ids: [String]) async -> [String: Frame] {
        let rows = await fetchRows(ids)
        state.appendLog("已记录 \(rows.count)/\(ids.count) 张卡片的位置和尺寸（撤销用）")
        return rows.mapValues(\.frame)
    }

    /// Current rows of `ids`, read with one `board-content` per board (plus `card-content` for
    /// the first card of a board we have not seen, and for any card the board listing misses).
    private func fetchRows(_ ids: [String]) async -> [String: CardRow] {
        var frames: [String: CardRow] = [:]
        let scopes = ids.reduce(into: [String]()) { acc, id in
            let s = String(id.prefix { $0 != ":" })
            if !acc.contains(s) { acc.append(s) }
        }
        for scope in scopes {
            let scopeIds = ids.filter { $0.hasPrefix(scope + ":") }
            if boardIdByScope[scope] == nil, let first = scopeIds.first, let row = await readCard(first) {
                frames[row.id] = row
                boardIdByScope[scope] = row.parentDocumentId
            }
            if let boardId = boardIdByScope[scope] {
                let r = await exec(["board-content", boardId, "--format", "json"], showStdout: false)
                if r.ok {
                    for row in decodeRows(r.stdout) where scopeIds.contains(row.id) { frames[row.id] = row }
                } else {
                    boardIdByScope[scope] = nil // stale cache; fall back to card-content below
                }
            }
            for id in scopeIds where frames[id] == nil {
                if let row = await readCard(id) { frames[id] = row }
            }
        }
        lastRows = frames
        return frames
    }

    /// Fills `state.selectedCards` (titles, kinds, text excerpts) for the panel's card stack,
    /// then fetches thumbnails for the cards the stack shows (the first `CardStackView.visible`),
    /// each landing in `state.selectedCards` as it arrives so the panel never waits for them.
    func describeSelection() async {
        let ids = state.selectedCardIds
        state.selectedCards = ids.map { CardSummary(id: $0, title: "", kind: "", thumbnail: thumbnails.cached($0)) }
        guard !ids.isEmpty else { return }
        let rows = await fetchRows(ids)
        guard state.selectedCardIds == ids else { return } // selection changed meanwhile
        state.selectedCards = ids.map { id in
            let row = rows[id]
            return CardSummary(id: id, title: row?.title ?? "", kind: row?.kind ?? "",
                               excerpt: Self.excerpt(row?.document?.body),
                               documentId: row?.document?.id,
                               thumbnail: thumbnails.cached(id))
        }
        Log.info("selection described: " + state.selectedCards.map { "\($0.kind):\($0.title)" }.joined(separator: " | "))
        for card in state.selectedCards.prefix(CardStackView.visible)
        where card.thumbnail == nil && ThumbnailLoader.hasThumbnail(kind: card.kind) {
            Task { @MainActor in
                guard let img = await thumbnails.thumbnail(for: card),
                      let i = state.selectedCards.firstIndex(where: { $0.id == card.id }) else { return }
                state.selectedCards[i].thumbnail = img
            }
        }
    }

    /// First line-ish of a text body for the card face: whitespace collapsed, at most 60 characters.
    private static func excerpt(_ body: String?) -> String {
        guard let body else { return "" }
        let words = body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(words.prefix(60))
    }

    /// Dispatches a command picked in the panel.
    func run(_ kind: CommandKind) async {
        switch kind {
        case .gather(let layout, let columns, let order): await gather(layout: layout, columns: columns, order: order)
        case .resize(let w, let h): await resizeAll(width: w, height: h)
        case .undo: await undo()
        }
    }

    private static func num(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
    }

    private func moveBack(_ id: String, to f: Frame) -> [String] {
        ["card-move", "--id", id, "--x", Self.num(f.x), "--y", Self.num(f.y),
         "--width", Self.num(f.width), "--height", Self.num(f.height)]
    }

    /// Runs a frame-changing step: snapshot first, run `body` with the snapshot, and if it did
    /// anything, make the snapshot the undo entry. Cards whose frame could not be read are not
    /// restorable; say so.
    private func frameStep(label: String, _ body: ([String: Frame]) async -> Bool) async {
        let ids = state.selectedCardIds
        let before = await snapshotFrames(ids)
        let missing = ids.filter { before[$0] == nil }
        if !missing.isEmpty {
            state.appendLog("警告：\(missing.count) 张卡片读不到位置，撤销时不会恢复它们")
        }
        guard await body(before) else { return }
        state.status = "已\(label)"
        guard !before.isEmpty else { state.appendLog("没有可撤销的记录"); return }
        undoEntry = UndoEntry(label: label,
                              commands: ids.compactMap { id in before[id].map { moveBack(id, to: $0) } })
        state.appendLog("可撤销：\(label)")
    }

    // MARK: - Commands

    /// Lays the selection out as a grid anchored at the selection's top-left corner (the smallest
    /// x and smallest y among the selected cards), not at the board origin, and in reading order
    /// (by y, then x) so the grid keeps the cards' visual order. Falls back to (80, 80) when no
    /// frame could be read.
    func gatherGrid(columns: Int) async { await gather(layout: "grid", columns: columns, order: SortOrder()) }

    /// `layout` is grid, row or column (card-gather's vocabulary); `columns` only matters for grid.
    /// `order` picks the sequence the cards fill the layout in: reading order (y, then x),
    /// by title, or by creation time, optionally reversed.
    func gather(layout: String, columns: Int, order: SortOrder) async {
        await guarded {
            let cols = max(1, columns)
            var label = layout == "grid" ? "排成 \(cols) 列" : (layout == "row" ? "排成一行" : "排成一列")
            if let o = order.label { label += "（\(o)）" }
            await frameStep(label: label) { frames in
                let known = state.selectedCardIds.compactMap { id in frames[id].map { (id, $0) } }
                let originX = known.map(\.1.x).min() ?? 80
                let originY = known.map(\.1.y).min() ?? 80
                var ordered = known.sorted { a, b in
                    switch order.key {
                    case .visual:
                        return abs(a.1.y - b.1.y) > 1 ? a.1.y < b.1.y : a.1.x < b.1.x
                    case .title:
                        let ta = lastRows[a.0]?.title ?? "", tb = lastRows[b.0]?.title ?? ""
                        return ta.localizedStandardCompare(tb) == .orderedAscending
                    case .created:
                        return (lastRows[a.0]?.createdAt ?? "") < (lastRows[b.0]?.createdAt ?? "")
                    }
                }.map(\.0)
                if order.reversed { ordered.reverse() }
                let ids = ordered + state.selectedCardIds.filter { !ordered.contains($0) }
                var args = ["card-gather", "--ids", ids.joined(separator: ","), "--layout", layout,
                            "--x", Self.num(originX), "--y", Self.num(originY), "--spacing", "40"]
                if layout == "grid" { args += ["--columns", "\(cols)"] }
                return await exec(args).ok
            }
        }
    }

    func resizeAll(width: Int = 200, height: Int = 150) async {
        await guarded {
            let name = CommandCatalog.sizes.first { $0.width == width && $0.height == height }?.name
            await frameStep(label: name.map { "统一大小：\($0)" } ?? "统一尺寸 \(width)×\(height)") { _ in
                var any = false
                for id in state.selectedCardIds {
                    if await exec(["card-move", "--id", id, "--width", "\(width)", "--height", "\(height)"]).ok { any = true }
                }
                return any
            }
        }
    }

    // MARK: - Undo

    var canUndo: Bool { undoEntry != nil }

    func undo() async {
        guard !state.isRunning, let entry = undoEntry else { return }
        state.isRunning = true
        defer { state.isRunning = false }
        undoEntry = nil
        state.appendLog("撤销：\(entry.label)")
        var failed = 0
        for cmd in entry.commands where !(await exec(cmd).ok) { failed += 1 }
        state.status = failed == 0 ? "已撤销：\(entry.label)" : "撤销 \(entry.label)：\(failed)/\(entry.commands.count) 条失败"
        state.appendLog(state.status)
    }
}
