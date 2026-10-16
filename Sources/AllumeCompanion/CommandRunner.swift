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
    init(state: AppState) { self.state = state }

    // MARK: - Undo state

    private struct Frame: Decodable, Equatable {
        let x: Double, y: Double, width: Double, height: Double
    }

    /// One `board-content` / `card-content` row; only the fields we need.
    private struct CardRow: Decodable {
        let id: String
        let kind: String?
        let frame: Frame
        let parentDocumentId: String?
    }

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
        if !r.ok { state.appendLog("exit \(r.status)") }
        return r
    }

    private func guarded(_ body: () async -> Void) async {
        guard !state.isRunning else { return }
        guard !state.selectedCardIds.isEmpty else { state.appendLog("没有选中的卡片。先按 ⌘K 读取。"); return }
        state.isRunning = true
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

    /// Current frames of `ids`, read with one `board-content` per board (plus `card-content` for
    /// the first card of a board we have not seen, and for any card the board listing misses).
    private func snapshotFrames(_ ids: [String]) async -> [String: Frame] {
        var frames: [String: Frame] = [:]
        let scopes = ids.reduce(into: [String]()) { acc, id in
            let s = String(id.prefix { $0 != ":" })
            if !acc.contains(s) { acc.append(s) }
        }
        for scope in scopes {
            let scopeIds = ids.filter { $0.hasPrefix(scope + ":") }
            if boardIdByScope[scope] == nil, let first = scopeIds.first, let row = await readCard(first) {
                frames[row.id] = row.frame
                boardIdByScope[scope] = row.parentDocumentId
            }
            if let boardId = boardIdByScope[scope] {
                let r = await exec(["board-content", boardId, "--format", "json"], showStdout: false)
                if r.ok {
                    for row in decodeRows(r.stdout) where scopeIds.contains(row.id) { frames[row.id] = row.frame }
                } else {
                    boardIdByScope[scope] = nil // stale cache; fall back to card-content below
                }
            }
            for id in scopeIds where frames[id] == nil {
                if let row = await readCard(id) { frames[id] = row.frame }
            }
        }
        state.appendLog("已记录 \(frames.count)/\(ids.count) 张卡片的位置和尺寸（撤销用）")
        return frames
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
    func gatherGrid(columns: Int) async {
        await guarded {
            let cols = max(1, columns)
            await frameStep(label: "排成 \(cols) 列") { frames in
                let known = state.selectedCardIds.compactMap { id in frames[id].map { (id, $0) } }
                let originX = known.map(\.1.x).min() ?? 80
                let originY = known.map(\.1.y).min() ?? 80
                let ordered = known.sorted { a, b in
                    abs(a.1.y - b.1.y) > 1 ? a.1.y < b.1.y : a.1.x < b.1.x
                }.map(\.0)
                let ids = ordered + state.selectedCardIds.filter { !ordered.contains($0) }
                return await exec(["card-gather", "--ids", ids.joined(separator: ","), "--layout", "grid",
                                   "--columns", "\(cols)", "--x", Self.num(originX), "--y", Self.num(originY),
                                   "--spacing", "40"]).ok
            }
        }
    }

    func resizeAll(width: Int = 200, height: Int = 150) async {
        await guarded {
            await frameStep(label: "统一尺寸 \(width)×\(height)") { _ in
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
        state.appendLog(failed == 0 ? "已撤销：\(entry.label)" : "撤销 \(entry.label)：\(failed)/\(entry.commands.count) 条失败")
    }
}
