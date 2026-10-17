import SwiftUI

extension Notification.Name {
    /// Posted by OverlayController when the panel is shown: the field refocuses (and clears, in
    /// case `panelReset` did not run).
    static let panelShown = Notification.Name("AllumeCompanion.panelShown")
    /// Posted by OverlayController right after the panel is hidden: the field clears and the
    /// selection goes back to the first row, so the next show has nothing to re-layout.
    static let panelReset = Notification.Name("AllumeCompanion.panelReset")
    /// Test hook (`ALLUME_USR2=type:<text>`): puts `object` (a String) into the panel's field.
    static let panelQuery = Notification.Name("AllumeCompanion.panelQuery")
}

/// Allume's own palette, so the panel reads as part of it rather than a generic blue sheet.
enum Theme {
    /// Allume's accent (its asset catalog's `accent`, Display P3 0.388/0.165/0.961): selection
    /// highlight, count badge, and the filament on the app icon.
    static let accent = Color(.displayP3, red: 0.388, green: 0.165, blue: 0.961)
    /// Text levels as plain opacities of the label color, not the hierarchical `.secondary`:
    /// inside the glass those rendered nearly as dark as the titles (seen in snapshots), so a
    /// title and its subtitle could not be told apart. Plain opacities read the same everywhere.
    static let text1 = Color.primary.opacity(0.88)
    static let text2 = Color.primary.opacity(0.5)
    static let text3 = Color.primary.opacity(0.3)
}

enum PanelMetrics {
    static let cornerRadius: CGFloat = 16
    /// The window never changes size or jumps; everything that changes on its own fades:
    /// the window in and out, the rows once the selection is known, the card stack and the
    /// field's hint when they change.
    static let fadeIn: TimeInterval = 0.12
    static let fadeOut: TimeInterval = 0.1
    static let rowsFade: TimeInterval = 0.12
    static let crossFade: TimeInterval = 0.15
    // Raycast's grid: everything hangs off one left edge (`inset`), the field's text starts
    // where the row titles start (`inset + icon + iconGap`), rows are one line.
    static let inset: CGFloat = 16
    static let icon: CGFloat = 22
    static let iconGap: CGFloat = 10
    static let searchRow: CGFloat = 56
    static let row: CGFloat = 40
    /// A section title ("排列", "白板") above its rows.
    static let header: CGFloat = 30
    static let listPadding: CGFloat = 6
    static let footer: CGFloat = 40
    static let maxRows = 9
    /// The list area, always this tall (like Raycast): fewer rows leave space below, more scroll.
    static let list = CGFloat(maxRows) * row + 2 * listPadding
    /// The panel's one height.
    static let maxHeight = searchRow + 1 + list + 1 + footer
    static let width: CGFloat = 640
}

extension CommandGroup {
    /// Icon color of the group's commands (Raycast-style colored squares).
    var tint: Color {
        switch self {
        case .board: return .teal
        case .arrange: return Theme.accent
        case .size: return .pink
        case .navigate: return .blue
        case .create: return .green
        case .edit: return .gray
        }
    }
}

/// A run of rows under one title; `title` is nil for an untitled list (the navigation lists).
struct PanelSection: Identifiable {
    let id: String
    let title: String?
    var rows: [PanelRow]
}

/// One row of the panel, whatever list is showing: a command, a recently visited board, or a
/// todo. Laid out like Raycast on one line: colored icon, title, grey subtitle (`hint`), and a
/// grey `accessory` at the right edge. `run` is what ⏎ does; `action` names it in the footer.
struct PanelRow: Identifiable {
    let id: String
    let symbol: String
    var tint: Color = .gray
    let title: String
    let hint: String
    /// What kind of row, or a short status ("今天", "已过期 2 天", "3 小时前").
    var accessory: String? = nil
    var accessoryIsUrgent = false
    var action = "执行"
    let run: () -> Void
}

/// Spotlight-style command panel: a stack of the selected cards on the left, a command field,
/// and the matching rows below, in titled sections. With an empty field the sections are the
/// commands that fit the selection (none / one card / several / one sub-board), grouped by
/// `CommandGroup`; typing ranks a "命令", a "白板" (BoardIndex) and a "待办" section against
/// each other. Between ⌘K and the selection being known the list is empty; then the rows fade in. ↑/↓ pick, ⏎ runs, Esc or ⌘K closes. Two rows are not commands
/// but lists ("最近去过", "全部待办"): ⏎ on them swaps the rows for that list (filtered by what
/// is typed), ⏎ on a list row jumps to its board, Esc or ⌫ on an empty field comes back.
struct CommandPanelView: View {
    @ObservedObject var state: AppState
    let runner: CommandRunner
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    private var context: SelectionContext {
        let one = state.selectedCards.count == 1 ? state.selectedCards.first : nil
        return SelectionContext(count: state.selectedCardIds.count,
                                singleBoard: one?.kind == "subBoard" && one?.documentId != nil,
                                canUndo: state.undoLabel != nil)
    }

    private var matches: [CommandMatch] {
        let ctx = context
        return CommandCatalog.matches(for: query).filter { CommandCatalog.isAvailable($0.spec, in: ctx) }
    }

    /// Board and todo search results get at most this many rows each.
    private static let searchLimit = 6

    private var sections: [PanelSection] {
        switch state.panelMode {
        case .commands:
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return CommandGroup.allCases.compactMap { g in
                    let rows = matches.filter { $0.spec.group == g }.map(commandRow)
                    return rows.isEmpty ? nil : PanelSection(id: "g\(g.rawValue)", title: g.title, rows: rows)
                }
            }
            return searchSections(trimmed)
        case .recentBoards: return [PanelSection(id: "list", title: nil, rows: filtered(state.recentBoards.map(boardRow)))]
        case .allTodos: return [PanelSection(id: "list", title: nil, rows: filtered(state.todos.map(todoRow)))]
        case .addTodo: return [PanelSection(id: "list", title: nil, rows: addTodoRows)]
        }
    }

    /// Typing: commands, boards and todos, each section ranked by how well its best row
    /// matches (per-word, same 4…1 scale); ties keep that order.
    private func searchSections(_ q: String) -> [PanelSection] {
        var ranked: [(score: Double, section: PanelSection)] = []
        let cmds = matches
        if let best = cmds.first {
            let words = max(1, CommandCatalog.normalizedWords(q).count)
            ranked.append((Double(best.score) / Double(words), PanelSection(id: "cmd", title: "命令", rows: cmds.map(commandRow))))
        }
        let boards = state.boards
            .map { (b: $0, s: CommandCatalog.textScore(q, $0.title)) }
            .filter { $0.s > 0 }
            .sorted { $0.s != $1.s ? $0.s > $1.s : $0.b.lastSeen > $1.b.lastSeen }
            .prefix(Self.searchLimit)
        if let best = boards.first {
            ranked.append((Double(best.s), PanelSection(id: "boards", title: "白板", rows: boards.map { searchBoardRow($0.b) })))
        }
        let todos = state.todos
            .map { (t: $0, s: CommandCatalog.textScore(q, $0.label)) }
            .filter { $0.s > 0 }
            .sorted { $0.s > $1.s } // stable: due order within a score
            .prefix(Self.searchLimit)
        if let best = todos.first {
            ranked.append((Double(best.s), PanelSection(id: "todos", title: "待办", rows: todos.map { todoRow($0.t, idPrefix: "t:") })))
        }
        return ranked.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element.section)
    }

    private var rows: [PanelRow] { sections.flatMap(\.rows) }

    /// The rows are invisible (not removed) while the selection is being read; AppDelegate fades
    /// them in by flipping `selectionPending` inside `withAnimation`.
    private var listHidden: Bool { state.panelMode == .commands && state.selectionPending }

    /// The "添加待办" field's rows: first what ⏎ adds (the exact body that will be written, the
    /// same `@todo(due: …) 内容` line `TodoIndex` reads), then the date phrases the half-typed
    /// tail could become (`下周` → 下周一 … 下周日); picking one, or Tab for the first, swaps the
    /// tail for its date. A finished phrase is swapped as soon as it is typed (`autoReplaceDate`).
    private var addTodoRows: [PanelRow] {
        let raw = query // runSelected clears the field before the row runs
        let draft = TodoDraft.parse(raw)
        let board = runner.boardModel?.title ?? state.boardTitle
        let place = board.isEmpty ? "当前白板" : "「\(board)」"
        let dueText = draft.due.flatMap { iso in DateWords.match(in: iso, atEnd: true).map { DateWords.describe($0.date) } }
        var rows = [PanelRow(id: "add-todo-draft", symbol: "plus", tint: CommandGroup.create.tint,
                             title: draft.text.isEmpty ? "输入待办内容" : draft.body,
                             hint: draft.text.isEmpty ? "日期写在开头或末尾：明天、下周二、月底、3天后、10-20"
                                                      : "贴到\(place)" + (draft.due == nil ? "，没有到期日" : ""),
                             accessory: dueText, action: "添加") {
            guard !draft.text.isEmpty else { return }
            Task { await runner.addTodo(raw) }
        }]
        if let c = DateWords.completions(for: raw) {
            for p in c.phrases {
                let filled = raw.replacingCharacters(in: c.fragment, with: DateWords.iso(p.date))
                rows.append(PanelRow(id: "date-" + p.text, symbol: "calendar", tint: .red, title: p.text,
                                     hint: "\(DateWords.iso(p.date)) · \(DateWords.describe(p.date))",
                                     accessory: "日期", action: "填入日期") {
                    query = filled
                })
            }
        }
        return rows
    }

    /// Tab in the "添加待办" field: take the highlighted date suggestion, or the first one.
    private func acceptDate() -> Bool {
        let list = addTodoRows
        guard list.count > 1 else { return false }
        list[selectedIndex > 0 && list.indices.contains(selectedIndex) ? selectedIndex : 1].run()
        return true
    }

    private func autoReplaceDate() {
        guard state.panelMode == .addTodo, let replaced = DateWords.autoReplace(query) else { return }
        query = replaced
    }

    private func filtered(_ rows: [PanelRow]) -> [PanelRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.title.lowercased().contains(q) || $0.hint.lowercased().contains(q) }
    }

    private func commandRow(_ m: CommandMatch) -> PanelRow {
        var hint = m.spec.hint
        var accessory = "命令"
        var urgent = false
        var action = "执行"
        switch m.kind {
        case .recentBoards:
            hint = state.recentBoards.first.map { "上一站「\($0.title)」" } ?? "切换白板时会记下来"
            accessory = state.recentBoards.first.map { relativeTime($0.at) } ?? accessory
            action = "打开列表"
        case .allTodos:
            let due = state.todos.filter { ($0.daysLeft() ?? 1) <= 0 }.count
            hint = state.todos.isEmpty ? "还没有 @todo 卡" : "\(state.todos.count) 条"
            if due > 0 { accessory = "\(due) 条到期"; urgent = true }
            action = "打开列表"
        case .undo:
            if let label = state.undoLabel { hint = "撤回「\(label)」" }
        case .home, .openSelectedBoard: action = "跳转"
        case .addTodo: action = "新建"
        default: break
        }
        var title = m.title
        if case .openSelectedBoard = m.kind, let card = state.selectedCards.first, !card.title.isEmpty {
            title = "打开「\(card.title)」"
        }
        return PanelRow(id: m.id, symbol: m.spec.symbol, tint: m.spec.group.tint, title: title, hint: hint,
                        accessory: accessory, accessoryIsUrgent: urgent, action: action) {
            switch m.kind {
            case .recentBoards: state.panelMode = .recentBoards
            case .allTodos: state.panelMode = .allTodos
            case .addTodo: state.panelMode = .addTodo
            default: Task { await runner.run(m.kind) }
            }
        }
    }

    private func boardRow(_ v: VisitTrail.Visit) -> PanelRow {
        PanelRow(id: v.boardId, symbol: "rectangle.on.rectangle", tint: CommandGroup.board.tint,
                 title: v.title.isEmpty ? "（无标题白板）" : v.title,
                 hint: state.boards.first { $0.id == v.boardId }?.path ?? "",
                 accessory: relativeTime(v.at), action: "跳转") {
            Task { await runner.openBoard(id: v.boardId, title: v.title) }
        }
    }

    private func searchBoardRow(_ b: BoardRef) -> PanelRow {
        PanelRow(id: "b:" + b.id, symbol: "rectangle.on.rectangle", tint: CommandGroup.board.tint,
                 title: b.title.isEmpty ? "（无标题白板）" : b.title,
                 hint: b.path.isEmpty ? "workspace 首页" : b.path, accessory: "白板", action: "跳转") {
            Task { await runner.openBoard(id: b.id, title: b.title) }
        }
    }

    private func todoRow(_ t: TodoItem) -> PanelRow { todoRow(t, idPrefix: "") }

    private func todoRow(_ t: TodoItem, idPrefix: String) -> PanelRow {
        let days = t.daysLeft()
        return PanelRow(id: idPrefix + t.cardId, symbol: (days ?? 1) <= 0 ? "exclamationmark" : "checkmark",
                        tint: (days ?? 1) <= 0 ? .red : .orange,
                        title: t.label, hint: t.boardTitle,
                        accessory: t.dueLabel ?? "待办", accessoryIsUrgent: (days ?? 1) <= 0, action: "跳到白板") {
            Task { await runner.openBoard(id: t.boardId, title: t.boardTitle) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchRow
            Divider()
            results
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { panelBackground }
        .onAppear { fieldFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .panelShown)) { _ in
            if !query.isEmpty { query = "" }
            if selectedIndex != 0 { selectedIndex = 0 }
            fieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelReset)) { _ in
            if !query.isEmpty { query = "" }
            if selectedIndex != 0 { selectedIndex = 0 }
            if state.panelMode != .commands { state.panelMode = .commands }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelQuery)) { note in
            if let s = note.object as? String { query = s }
        }
        .onChange(of: query) { _, _ in selectedIndex = 0; autoReplaceDate() }
        .onChange(of: state.panelMode) { _, _ in query = ""; selectedIndex = 0; fieldFocused = true }
    }

    /// On macOS 26 the Liquid Glass is the panel's NSGlassEffectView (OverlayController), so
    /// nothing here; the regular material with a hairline edge before that.
    @ViewBuilder private var panelBackground: some View {
        if #available(macOS 26.0, *) {
            Color.clear
        } else {
            RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius).fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius).strokeBorder(.quaternary))
        }
    }

    // MARK: - Search row

    private var searchRow: some View {
        HStack(spacing: PanelMetrics.iconGap) {
            leadingIcon
            // The hint is drawn by hand so a change (entering a list) cross-fades.
            TextField("", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .background(alignment: .leading) {
                    if query.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .id(placeholder)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: PanelMetrics.crossFade), value: placeholder)
                .focused($fieldFocused)
                .onSubmit { runSelected() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.tab) {
                    if state.panelMode == .addTodo, acceptDate() { return .handled }
                    move(1); return .handled
                }
                .onKeyPress(.delete) {
                    guard query.isEmpty, state.panelMode != .commands else { return .ignored }
                    state.panelMode = .commands
                    return .handled
                }
            if state.isRunning { ProgressView().controlSize(.small) }
            selectionChip
        }
        .padding(.leading, PanelMetrics.inset)
        .padding(.trailing, PanelMetrics.inset)
        .frame(height: PanelMetrics.searchRow)
    }

    /// Left of the field, the same size as a row icon so the field's text lines up with the row
    /// titles: the app icon, or in a list that list's icon. A change cross-fades.
    private var leadingIcon: some View {
        ZStack {
            if state.panelMode == .commands {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: PanelMetrics.icon + 4, height: PanelMetrics.icon + 4)
                    .transition(.opacity)
            } else {
                RowIcon(symbol: modeSymbol, tint: modeTint).transition(.opacity)
            }
        }
        .frame(width: PanelMetrics.icon, height: PanelMetrics.icon)
        .animation(.easeOut(duration: PanelMetrics.crossFade), value: state.panelMode)
    }

    /// Right end of the search row (where Raycast puts its accessory): what is selected, as a
    /// small card stack and a label. Fades in when the selection arrives; the field never moves.
    private var selectionChip: some View {
        let show = state.panelMode == .commands && !state.selectedCardIds.isEmpty
        let n = state.selectedCardIds.count
        let title = state.selectedCards.first?.title ?? ""
        let label = n == 1 && !title.isEmpty ? (title.count > 14 ? title.prefix(13) + "…" : title) : "\(n) 张卡"
        return HStack(spacing: 8) {
            if show {
                CardStackView(cards: state.selectedCards, count: n)
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.text2).lineLimit(1)
                    .fixedSize()
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: PanelMetrics.crossFade), value: show)
    }

    private var footerKeys: String {
        switch state.panelMode {
        case .commands: return "↑↓ 选择 · ⏎ 执行 · Esc 关闭"
        case .addTodo: return "⏎ 添加 · Tab 补全日期 · Esc 返回"
        default: return "↑↓ 选择 · ⏎ 跳转 · Esc 返回"
        }
    }

    private var modeSymbol: String {
        switch state.panelMode {
        case .allTodos: return "checklist"
        case .addTodo: return "plus"
        default: return "clock.arrow.circlepath"
        }
    }

    private var modeTint: Color {
        state.panelMode == .addTodo ? CommandGroup.create.tint : CommandGroup.navigate.tint
    }

    /// With nothing selected the field just invites a command; the reason nothing was read
    /// (timeout, no Allume…) goes to the log, not in the user's face.
    private var placeholder: String {
        switch state.panelMode {
        case .recentBoards: return "筛选最近去过的白板…"
        case .allTodos: return "筛选待办…"
        case .addTodo: return "待办内容，加个日期：下周二 交房租"
        case .commands: return "搜索命令、白板、待办…"
        }
    }

    // MARK: - Results

    private var emptyText: String {
        switch state.panelMode {
        case .commands: return "没有匹配的结果"
        case .recentBoards: return state.recentBoards.isEmpty ? "还没有足迹：切换白板时会记下来" : "没有匹配的白板"
        case .allTodos: return state.todos.isEmpty ? "没有待办：正文第一行写 @todo 的文字卡会出现在这里" : "没有匹配的待办"
        case .addTodo: return ""
        }
    }

    /// The only scrolling part: at most `maxList` tall, the selected row (or, for the first row
    /// of a section, its title) is kept in view.
    private var results: some View {
        let sections = self.sections
        // Index (in `rows`) of each section's first row.
        let firstIndex = sections.reduce(into: [Int]()) { acc, sec in
            acc.append(acc.isEmpty ? 0 : acc.last! + sections[acc.count - 1].rows.count)
        }
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { si, section in
                        if let title = section.title {
                            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                                .padding(.horizontal, PanelMetrics.inset - 8)
                                .padding(.bottom, 6)
                                .frame(height: PanelMetrics.header, alignment: .bottomLeading)
                                .id("h:" + section.id)
                        }
                        ForEach(Array(section.rows.enumerated()), id: \.element.id) { ri, r in
                            let i = firstIndex[si] + ri
                            ResultRow(row: r, selected: i == selectedIndex)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedIndex = i; runSelected() }
                                .id(r.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, PanelMetrics.listPadding)
            }
            .overlay {
                if sections.allSatisfy({ $0.rows.isEmpty }), !emptyText.isEmpty {
                    Text(emptyText).font(.system(size: 13)).foregroundStyle(Theme.text2)
                }
            }
            .frame(height: PanelMetrics.list)
            .opacity(listHidden ? 0 : 1)
            .onChange(of: selectedIndex) { _, i in
                guard let si = firstIndex.lastIndex(where: { $0 <= i }), sections.indices.contains(si) else { return }
                let section = sections[si]
                if i == firstIndex[si], section.title != nil {
                    proxy.scrollTo("h:" + section.id, anchor: nil)
                } else if section.rows.indices.contains(i - firstIndex[si]) {
                    proxy.scrollTo(section.rows[i - firstIndex[si]].id, anchor: nil)
                }
            }
        }
    }

    /// Raycast's action bar: where you are (or the last result) on the left; on the right what
    /// ⏎ does to the highlighted row and what Esc does, with their keys.
    private var footer: some View {
        HStack(spacing: 8) {
            footerLeft
            Spacer(minLength: 12)
            if !listHidden, rows.indices.contains(selectedIndex) {
                Text(rows[selectedIndex].action).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text1)
                KeyCap("↩")
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 4)
            }
            if state.panelMode == .addTodo {
                Text("补全日期").font(.system(size: 12)).foregroundStyle(Theme.text2)
                KeyCap("tab")
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 4)
            }
            Text(state.panelMode == .commands ? "关闭" : "返回").font(.system(size: 12)).foregroundStyle(Theme.text2)
            KeyCap("esc")
        }
        .padding(.horizontal, PanelMetrics.inset)
        .frame(height: PanelMetrics.footer)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder private var footerLeft: some View {
        HStack(spacing: 6) {
            if state.panelMode == .commands, !state.status.isEmpty {
                Image(systemName: state.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(state.statusIsError ? Color.orange : Color.green)
                Text(state.status).foregroundStyle(Theme.text2)
            } else if state.panelMode == .allTodos {
                Text("全部待办 · \(rows.count) 条").foregroundStyle(Theme.text2)
            } else if state.panelMode == .recentBoards {
                Text("最近去过 · \(rows.count) 块白板").foregroundStyle(Theme.text2)
            } else if !state.boardTitle.isEmpty {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(Theme.text3)
                Text(state.boardTitle).foregroundStyle(Theme.text2)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }

    // MARK: - Actions

    private func move(_ delta: Int) {
        let n = rows.count
        guard n > 0 else { return }
        selectedIndex = (selectedIndex + delta + n) % n
    }

    private func runSelected() {
        let list = rows
        guard list.indices.contains(selectedIndex) else { return }
        let row = list[selectedIndex]
        query = ""
        row.run()
    }
}

/// One line, Raycast-style: colored icon, title, grey subtitle, grey accessory at the right.
/// The highlighted row gets a light grey rounded background; nothing else about it changes.
private struct ResultRow: View {
    let row: PanelRow
    let selected: Bool

    var body: some View {
        HStack(spacing: PanelMetrics.iconGap) {
            RowIcon(symbol: row.symbol, tint: row.tint)
            Text(row.title).font(.system(size: 14)).foregroundStyle(Theme.text1)
                .lineLimit(1).layoutPriority(1)
            Text(row.hint).font(.system(size: 14)).foregroundStyle(Theme.text2)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let a = row.accessory {
                if row.accessoryIsUrgent {
                    // A filled tag, not red text: colored text inside the glass rendered black in snapshots.
                    Text(a).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Color.red.opacity(0.85), in: Capsule())
                        .lineLimit(1).layoutPriority(1)
                } else {
                    Text(a).font(.system(size: 13)).foregroundStyle(Theme.text2)
                        .lineLimit(1).layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, PanelMetrics.inset - 8)
        .frame(height: PanelMetrics.row)
        .background {
            if selected { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)) }
        }
    }
}

/// A white SF Symbol on a colored rounded square, like Raycast's command icons.
struct RowIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.8), tint], startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: PanelMetrics.icon, height: PanelMetrics.icon)
    }
}

/// A key on the footer: "↩", "esc", "tab".
private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Up to three small overlapping cards: the "what you selected" token at the right of the
/// search row (the count is in the label next to it).
struct CardStackView: View {
    let cards: [CardSummary]
    let count: Int

    /// How many faces the stack draws (and how many thumbnails are fetched per ⌘K).
    static let visible = 3
    private let size = CGSize(width: 30, height: 22)

    var body: some View {
        let shown = min(max(cards.count, 1), Self.visible)
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(cards.prefix(Self.visible).enumerated().reversed()), id: \.element.id) { i, card in
                CardFace(card: card, size: size)
                    .offset(x: CGFloat(i) * 4, y: CGFloat(i) * -3)
            }
        }
        .frame(width: size.width + CGFloat(shown - 1) * 4, height: size.height + CGFloat(shown - 1) * 3, alignment: .bottomLeading)
    }
}

/// One card in the stack: its thumbnail (aspect fill), else the kind's icon.
private struct CardFace: View {
    let card: CardSummary
    let size: CGSize

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let img = card.thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(Theme.text2)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: PanelMetrics.crossFade), value: card) // kind, thumbnail arrive later
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
    }

    private var symbol: String {
        switch card.kind {
        case "text", "chain": return "text.alignleft"
        case "url": return "link"
        case "image": return "photo"
        case "pdf", "file": return "doc"
        case "video": return "play.rectangle"
        case "subBoard": return "rectangle.on.rectangle"
        default: return "rectangle"
        }
    }
}
