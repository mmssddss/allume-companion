import AppKit
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
///
/// Where card data comes from (see README "当前白板模型"): `boardModel` holds the current board's
/// cards. Describing the selection reads from it when every selected card is there; the undo
/// snapshot only trusts it when it was loaded within `snapshotMaxAge`, otherwise it reads the
/// board again, because undo must restore the positions the cards really had before the write.
@MainActor
final class CommandRunner {
    let state: AppState
    /// Previews for the card stack, cached by card id.
    let thumbnails = ThumbnailLoader()
    /// Set by AppDelegate once the index and model exist.
    var boardModel: BoardModel?
    /// How recent the board model must be for an undo snapshot to use it instead of re-reading.
    static let snapshotMaxAge: TimeInterval = 2
    /// Ids of the companion's own boards (daily notes, projects; Companion.swift).
    let companion = CompanionStore()
    /// A board the runner wrote to and read back in full (a day board after "记到某天"), for
    /// TodoIndex; set by AppDelegate.
    var onBoardRead: ((_ id: String, _ title: String, _ rows: [BoardCard]) -> Void)?

    init(state: AppState) {
        self.state = state
        state.projects = companion.allProjects
    }

    // MARK: - Undo state

    private typealias Frame = BoardCard.Frame
    private typealias CardRow = BoardCard

    /// Rows cached by the last `fetchRows`, so `gather` can sort by title/createdAt without
    /// a second round of CLI calls.
    private var lastRows: [String: CardRow] = [:]

    struct UndoEntry {
        let label: String
        /// CLI invocations that reverse the step, run in order.
        let commands: [[String]]
        /// Bookkeeping to put back once the commands ran (the companion's project list).
        var after: (() -> Void)? = nil
    }

    var undoEntry: UndoEntry? {
        didSet { state.undoLabel = undoEntry?.label }
    }

    /// Cache: card-id scope prefix → parent board document id. The scope prefix of a card id is
    /// also the prefix of its board's document id, but the suffix differs and `board-content`
    /// rejects anything but the full document id, so we learn it once from `card-content`.
    private var boardIdByScope: [String: String] = [:]

    // MARK: - CLI

    @discardableResult
    func exec(_ args: [String], showStdout: Bool = true) async -> AllumeCLI.Result {
        state.appendLog(AllumeCLI.render(args))
        let r = await AllumeCLI.run(args)
        if showStdout, !r.stdout.isEmpty { state.appendLog(r.stdout) }
        if !r.stderr.isEmpty { state.appendLog("stderr: " + r.stderr) }
        if !r.ok {
            state.appendLog("exit \(r.status)")
            if AllumeSetup.isReadOnlyError(r.stderr) {
                state.cliWrite = .readOnly
                state.setStatus("Allume 的命令行工具是只读的：在 Allume 的设置 → CLI 里允许写入", error: true)
            } else {
                state.setStatus(r.stderr.split(separator: "\n").first.map(String.init) ?? "命令失败（exit \(r.status)）", error: true)
            }
        }
        return r
    }

    private func guarded(_ body: () async -> Void) async {
        guard !state.isRunning else { return }
        guard !state.selectedCardIds.isEmpty else { state.appendLog("没有选中的卡片。先按 ⌘K 读取。"); return }
        state.isRunning = true
        state.setStatus("")
        await body()
        state.isRunning = false
    }

    // MARK: - Frame snapshot

    private func decodeRows(_ json: String) -> [CardRow] { BoardCard.decodeRows(json) }

    private func readCard(_ id: String) async -> CardRow? {
        let r = await exec(["card-content", id, "--format", "json"], showStdout: false)
        return r.ok ? decodeRows(r.stdout).first : nil
    }

    /// Current frames of `ids`: from the board model when it holds all of them and was loaded
    /// within `snapshotMaxAge`, otherwise freshly read (see `fetchRows`).
    private func snapshotFrames(_ ids: [String]) async -> [String: Frame] {
        if let hit = boardModel?.lookup(ids), hit.age <= Self.snapshotMaxAge {
            lastRows = hit.rows
            state.appendLog("位置来自白板模型（\(String(format: "%.1f", hit.age)) 秒前读取），已记录 \(hit.rows.count)/\(ids.count) 张（撤销用）")
            return hit.rows.mapValues(\.frame)
        }
        let rows = await fetchRows(ids)
        state.appendLog("已记录 \(rows.count)/\(ids.count) 张卡片的位置和尺寸（撤销用）")
        return rows.mapValues(\.frame)
    }

    /// Current rows of `ids`, read with one `board-content` per board (plus `card-content` for
    /// the first card of a board we have not seen, and for any card the board listing misses).
    /// The board model and index already know most scope → board id pairs, so the
    /// `card-content` step is usually skipped. Every board read is handed to the model, so the
    /// next ⌘K on the same cards is answered from memory.
    private func fetchRows(_ ids: [String]) async -> [String: CardRow] {
        var frames: [String: CardRow] = [:]
        let scopes = ids.reduce(into: [String]()) { acc, id in
            let s = String(id.prefix { $0 != ":" })
            if !acc.contains(s) { acc.append(s) }
        }
        for scope in scopes {
            let scopeIds = ids.filter { $0.hasPrefix(scope + ":") }
            if boardIdByScope[scope] == nil, let known = boardModel?.boardId(forScope: scope) {
                boardIdByScope[scope] = known
            }
            if boardIdByScope[scope] == nil, let first = scopeIds.first, let row = await readCard(first) {
                frames[row.id] = row
                boardIdByScope[scope] = row.parentDocumentId
                if let parent = row.parentDocumentId, state.selectionFromAllume {
                    boardModel?.noteSelection(ids: ids, parentDocumentId: parent)
                }
            }
            if let boardId = boardIdByScope[scope] {
                let r = await exec(["board-content", boardId, "--format", "json"], showStdout: false)
                if r.ok {
                    let rows = decodeRows(r.stdout)
                    for row in rows where scopeIds.contains(row.id) { frames[row.id] = row }
                    boardModel?.adopt(boardId: boardId, rows: rows)
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
    ///
    /// Source: the board model when it holds every selected card (no CLI call: the current board
    /// or one of the other boards it keeps); otherwise (a board it has not seen, or not loaded
    /// yet) `fetchRows`, which hands what it reads to the model.
    func describeSelection() async {
        let ids = state.selectedCardIds
        state.selectedCards = ids.map { CardSummary(id: $0, title: "", kind: "", thumbnail: thumbnails.cached($0)) }
        guard !ids.isEmpty else { return }
        if state.selectionFromAllume { boardModel?.noteSelection(ids: ids) }
        let rows: [String: CardRow]
        let source: String
        if let hit = boardModel?.lookup(ids) {
            rows = hit.rows
            lastRows = hit.rows
            source = "board model (\(String(format: "%.1f", hit.age)) s old)"
        } else {
            source = boardModel?.boardId == nil ? "CLI (board model not loaded)" : "CLI (cards not in board model)"
            rows = await fetchRows(ids)
        }
        guard state.selectedCardIds == ids else { return } // selection changed meanwhile
        state.selectedCards = ids.map { id in
            let row = rows[id]
            return CardSummary(id: id, title: row?.title ?? "", kind: row?.kind ?? "",
                               excerpt: Self.excerpt(row?.document?.body),
                               documentId: row?.document?.id,
                               thumbnail: thumbnails.cached(id))
        }
        Log.info("selection described from \(source): " + state.selectedCards.map { "\($0.kind):\($0.title)" }.joined(separator: " | "))
        for card in state.selectedCards.prefix(CardStackView.visible)
        where card.thumbnail == nil && ThumbnailLoader.hasThumbnail(kind: card.kind) {
            Task { @MainActor in
                guard let img = await thumbnails.thumbnail(for: card),
                      let i = state.selectedCards.firstIndex(where: { $0.id == card.id }) else { return }
                state.selectedCards[i].thumbnail = img
            }
        }
    }

    /// The board model reloaded: refresh titles/kinds of the selection from it if it now covers
    /// them (no CLI call). Thumbnails already shown are kept.
    func refreshSelectionFromModel() {
        let ids = state.selectedCardIds
        guard !ids.isEmpty, let rows = boardModel?.lookup(ids)?.rows else { return }
        lastRows = rows
        let updated = ids.map { id -> CardSummary in
            let row = rows[id]!
            return CardSummary(id: id, title: row.title ?? "", kind: row.kind ?? "",
                               excerpt: Self.excerpt(row.document?.body),
                               documentId: row.document?.id,
                               thumbnail: thumbnails.cached(id))
        }
        if updated != state.selectedCards { state.selectedCards = updated }
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
        case .home: await goHome()
        case .day(let offset): await openDay(offset: offset)
        case .thisMonth: await openThisMonth()
        case .moveProjects(let target): await moveProjects(to: target)
        case .openSelectedBoard:
            guard let card = state.selectedCards.first, let id = card.documentId else { return }
            await openBoard(id: id, title: card.title)
        case .recentBoards, .allTodos, .addTodo, .addToDay, .addProject: break // modes of the panel view itself
        }
    }

    // MARK: - Jumping to a board

    /// `allume open <board>` and Allume to the front; the panel closes, since the user is leaving.
    ///
    /// Allume's `open` swaps the canvas and the window title but leaves the breadcrumb (top left)
    /// showing the previous board's path; any in-app back/forward redraws it with the right path.
    /// So open twice and step back once with ⌘[: we land on the second copy, nothing flashes,
    /// and the only trace is one extra forward entry pointing at the same board.
    func openBoard(id: String, title: String) async {
        state.requestHidePanel?()
        guard await exec(["open", id]).ok else { return }
        let again = await exec(["open", id], showStdout: false)
        state.setStatus("已打开「\(title)」")
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: AllumeTracker.bundleID).first else { return }
        app.activate()
        guard again.ok else { return }
        try? await Task.sleep(for: .milliseconds(150))
        state.appendLog("⌘[ → Allume（让它重画面包屑）")
        SelectionReader.postCommand(key: 33, to: app.processIdentifier) // kVK_ANSI_LeftBracket
    }

    private struct Workspace: Decodable { let title: String?; let rootBoardId: String? }

    /// Jumps to the root board of the workspace the current board is in: `list-workspaces` gives
    /// each workspace's root, and with several workspaces the one above the current board in
    /// `BoardIndex` wins (else the first).
    func goHome() async {
        state.requestHidePanel?()
        let r = await exec(["list-workspaces", "--format", "json"], showStdout: false)
        guard r.ok else { return }
        let roots = ((try? JSONDecoder().decode([Workspace].self, from: Data(r.stdout.utf8))) ?? [])
            .compactMap { w in w.rootBoardId.map { (id: $0, title: w.title ?? "") } }
        var above = Set<String>()
        var next = boardModel?.boardId
        while let id = next, above.insert(id).inserted { next = boardModel?.index.parentId(of: id) }
        guard let home = roots.first(where: { above.contains($0.id) }) ?? roots.first else {
            state.setStatus("list-workspaces 没有返回 workspace", error: true)
            return
        }
        await openBoard(id: home.id, title: home.title)
    }

    // MARK: - Adding a todo

    /// Sticks a todo on the current board: an untitled text card whose body is one marker line,
    /// `@todo(due: 2026-10-20) 交房租` (see `TodoDraft`), in the middle of what the user
    /// sees (`BoardViewport`), nudged to the nearest spot not covering other cards; when the
    /// viewport cannot be solved, right of the board's cards.
    func addTodo(_ raw: String) async {
        let draft = TodoDraft.parse(raw)
        guard !draft.text.isEmpty else { return }
        guard let model = boardModel, let boardId = model.boardId else {
            state.setStatus("还不知道当前是哪块白板，稍后再试", error: true)
            return
        }
        state.requestHidePanel?()
        var x = 80.0, y = 80.0
        if let pid = NSRunningApplication.runningApplications(withBundleIdentifier: AllumeTracker.bundleID).first?.processIdentifier,
           let fit = BoardViewport.fit(pid: pid, rows: model.rows) {
            // A new todo card comes out about 180×40; leave room for a longer line.
            let spot = BoardViewport.freeSpot(near: fit.center, size: CGSize(width: 240, height: 60), avoiding: model.rows.map(\.frame))
            x = spot.x; y = spot.y
            Log.info("add todo: viewport centre (\(Int(fit.center.x)), \(Int(fit.center.y))) at zoom \(String(format: "%.2f", fit.zoom)) from \(fit.pairs) titles")
        } else if let right = model.rows.map({ $0.frame.x + $0.frame.width }).max(), let top = model.rows.map(\.frame.y).min() {
            x = right + 40; y = top
            Log.info("add todo: viewport not solvable; placing right of the cards")
        }
        let r = await exec(["card-add", "--parent", boardId, "--text", draft.body,
                            "--x", Self.num(max(0, x.rounded())), "--y", Self.num(max(0, y.rounded())), "--format", "json"],
                           showStdout: false)
        guard r.ok else { return }
        state.setStatus("已在「\(model.title)」添加待办「\(draft.text)」" + (draft.due.map { "，\($0) 到期" } ?? ""))
        Task { await model.refresh(reason: "after add todo") }
    }

    static func idSuffix(_ id: String) -> String {
        id.split(separator: ":").last.map(String.init) ?? id
    }

    static func num(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
    }

    func moveBack(_ id: String, to f: BoardCard.Frame) -> [String] {
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
        let changed = await body(before)
        if let boardModel { Task { await boardModel.refresh(reason: "after \(label)") } }
        guard changed else { return }
        state.setStatus("已\(label)")
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
                        // board-content's createdAt is the call time, useless for ordering. Card ids
                        // carry a monotonic (HLC-style) prefix, so the id suffix is creation order.
                        return Self.idSuffix(a.0) < Self.idSuffix(b.0)
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
        entry.after?()
        state.setStatus(failed == 0 ? "已撤销：\(entry.label)" : "撤销 \(entry.label)：\(failed)/\(entry.commands.count) 条失败", error: failed > 0)
        state.appendLog(state.status)
        if let boardModel { Task { await boardModel.refresh(reason: "after undo") } }
    }
}
