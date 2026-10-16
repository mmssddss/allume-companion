import SwiftUI

/// The command panel: selection summary, three commands plus undo, CLI output.
struct CommandPanelView: View {
    @ObservedObject var state: AppState
    let runner: CommandRunner
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            commands
            Divider()
            output
            Text("Esc 或 ⌘K 关闭 · 再按 ⌘K 重新读取选中").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(state.selectedCardIds.isEmpty ? "没有选中的卡片" : "选中 \(state.selectedCardIds.count) 张卡")
                    .font(.headline)
                Spacer()
                if state.isRunning { ProgressView().controlSize(.small) }
            }
            if !state.selectionMessage.isEmpty {
                Text(state.selectionMessage).font(.caption).foregroundStyle(.secondary)
            }
            if !state.boardTitle.isEmpty {
                Text("白板：\(state.boardTitle)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 6) {
            selectionCommands
            Button(state.undoLabel.map { "撤销：\($0)" } ?? "撤销") { Task { await runner.undo() } }
                .keyboardShortcut("4", modifiers: [])
                .disabled(state.isRunning || state.undoLabel == nil)
        }
    }

    /// Commands that act on the current selection (the undo button lives outside this group
    /// because deleting empties the selection but must stay undoable).
    private var selectionCommands: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("排成 \(state.columns) 列") { Task { await runner.gatherGrid(columns: state.columns) } }
                    .keyboardShortcut("1", modifiers: [])
                Stepper("", value: $state.columns, in: 1...12).labelsHidden()
                Text("grid · x80 y80 · 间距 40").font(.caption).foregroundStyle(.tertiary)
            }
            Button("统一尺寸 200×150") { Task { await runner.resizeAll() } }
                .keyboardShortcut("2", modifiers: [])
            if confirmingDelete {
                HStack {
                    Text("确认删除 \(state.selectedCardIds.count) 张卡？").foregroundStyle(.red)
                    Button("删除", role: .destructive) {
                        confirmingDelete = false
                        Task { await runner.deleteAll() }
                    }
                    Button("取消") { confirmingDelete = false }.keyboardShortcut(.cancelAction)
                }
            } else {
                Button("删除…", role: .destructive) { confirmingDelete = true }
                    .keyboardShortcut("3", modifiers: [])
            }
        }
        .disabled(state.isRunning || state.selectedCardIds.isEmpty)
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(state.log.isEmpty ? "命令输出会显示在这里" : state.log)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(state.log.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("end")
            }
            .frame(maxHeight: .infinity)
            .onChange(of: state.log) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}
