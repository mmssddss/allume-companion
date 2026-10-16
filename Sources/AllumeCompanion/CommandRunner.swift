import Foundation

/// The three starter commands, each a thin wrapper over the CLI. Output is appended to `state.log`.
@MainActor
final class CommandRunner {
    let state: AppState
    init(state: AppState) { self.state = state }

    private func exec(_ args: [String]) async -> Bool {
        state.appendLog(AllumeCLI.render(args))
        let r = await AllumeCLI.run(args)
        if !r.stdout.isEmpty { state.appendLog(r.stdout) }
        if !r.stderr.isEmpty { state.appendLog("stderr: " + r.stderr) }
        if !r.ok { state.appendLog("exit \(r.status)") }
        return r.ok
    }

    private func guarded(_ body: () async -> Void) async {
        guard !state.isRunning else { return }
        guard !state.selectedCardIds.isEmpty else { state.appendLog("没有选中的卡片。先按 ⌘⇧P 读取。"); return }
        state.isRunning = true
        await body()
        state.isRunning = false
    }

    func gatherGrid(columns: Int) async {
        await guarded {
            let ids = state.selectedCardIds.joined(separator: ",")
            _ = await exec(["card-gather", "--ids", ids, "--layout", "grid", "--columns", "\(max(1, columns))",
                            "--x", "80", "--y", "80", "--spacing", "40"])
        }
    }

    func resizeAll(width: Int = 200, height: Int = 150) async {
        await guarded {
            for id in state.selectedCardIds {
                _ = await exec(["card-move", "--id", id, "--width", "\(width)", "--height", "\(height)"])
            }
        }
    }

    func deleteAll() async {
        await guarded {
            var deleted: [String] = []
            for id in state.selectedCardIds where await exec(["delete", id]) {
                deleted.append(id)
            }
            state.appendLog("已删除 \(deleted.count)/\(state.selectedCardIds.count) 张（可用 allume undelete <id> 恢复）")
            state.selectedCardIds.removeAll { deleted.contains($0) }
        }
    }
}
