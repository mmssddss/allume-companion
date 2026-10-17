import SwiftUI

extension Notification.Name {
    /// Posted by OverlayController when the panel is shown: the field refocuses (and clears, in
    /// case `panelReset` did not run).
    static let panelShown = Notification.Name("AllumeCompanion.panelShown")
    /// Posted by OverlayController right after the panel is hidden: the field clears and the
    /// selection goes back to the first row, so the next show has nothing to re-layout.
    static let panelReset = Notification.Name("AllumeCompanion.panelReset")
    /// Posted by the view with the height it wants (`object` is a CGFloat); the panel resizes
    /// from its top edge so the search row never moves and only the list scrolls.
    static let panelHeight = Notification.Name("AllumeCompanion.panelHeight")
    /// Test hook (`ALLUME_USR2=type:<text>`): puts `object` (a String) into the panel's field.
    static let panelQuery = Notification.Name("AllumeCompanion.panelQuery")
}

/// Allume's own palette, so the panel reads as part of it rather than a generic blue sheet.
enum Theme {
    /// Allume's accent (its asset catalog's `accent`, Display P3 0.388/0.165/0.961): selection
    /// highlight, count badge, and the filament on the app icon.
    static let accent = Color(.displayP3, red: 0.388, green: 0.165, blue: 0.961)
}

enum PanelMetrics {
    static let cornerRadius: CGFloat = 16
    /// Height changes (typing filters the list, the selection arrives or times out) animate
    /// over this, both the window frame (OverlayController) and the rows inside.
    static let resizeDuration: TimeInterval = 0.15
    static let searchRow: CGFloat = 62
    static let row: CGFloat = 46
    /// A section title ("排列", "白板") above its rows.
    static let header: CGFloat = 26
    static let listPadding: CGFloat = 16
    static let footer: CGFloat = 30
    static let maxRows = 8
    /// Taller lists scroll.
    static let maxList = CGFloat(maxRows) * row
    /// Field and footer only: the panel between ⌘K and the selection being known.
    static let collapsed = searchRow + footer
    static let maxHeight = height(list: maxList + listPadding)
    /// The list's height for that many rows and section titles (0 = folded away).
    static func listHeight(rows: Int, headers: Int) -> CGFloat {
        min(CGFloat(max(1, rows)) * row + CGFloat(headers) * header, maxList) + listPadding
    }
    static func height(list: CGFloat) -> CGFloat {
        searchRow + (list > 0 ? 1 + list : 0) + footer
    }
}

/// A run of rows under one title; `title` is nil for an untitled list (the navigation lists).
struct PanelSection: Identifiable {
    let id: String
    let title: String?
    var rows: [PanelRow]
}

/// One row of the panel, whatever list is showing: a command, a recently visited board, or a
/// todo. `run` is what ⏎ does.
struct PanelRow: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let hint: String
    /// Short status at the right edge (a todo's "今天" / "已过期 2 天"); nil for most rows.
    var trailing: String? = nil
    var trailingIsUrgent = false
    let run: () -> Void
}

/// Spotlight-style command panel: a stack of the selected cards on the left, a command field,
/// and the matching rows below, in titled sections. With an empty field the sections are the
/// commands that fit the selection (none / one card / several / one sub-board), grouped by
/// `CommandGroup`; typing ranks a "命令", a "白板" (BoardIndex) and a "待办" section against
/// each other. Between ⌘K and the selection being known only the field shows. ↑/↓ pick, ⏎ runs, Esc or ⌘K closes. Two rows are not commands
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
            if state.selectionPending { return [] }
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

    /// Folded away (0) while the selection is being read; otherwise rows plus section titles.
    private var listHeight: CGFloat {
        if state.panelMode == .commands && state.selectionPending { return 0 }
        let s = sections
        return PanelMetrics.listHeight(rows: s.reduce(0) { $0 + $1.rows.count }, headers: s.filter { $0.title != nil }.count)
    }

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
        var rows = [PanelRow(id: "add-todo", symbol: "plus.circle",
                             title: draft.text.isEmpty ? "输入待办内容" : draft.body,
                             hint: draft.text.isEmpty ? "⏎ 贴到\(place)；日期写在开头或末尾：明天、下周二、月底、3天后、10-20"
                                                      : "⏎ 贴到\(place)" + (draft.due == nil ? "；没有到期日" : ""),
                             trailing: dueText) {
            guard !draft.text.isEmpty else { return }
            Task { await runner.addTodo(raw) }
        }]
        if let c = DateWords.completions(for: raw) {
            for p in c.phrases {
                let filled = raw.replacingCharacters(in: c.fragment, with: DateWords.iso(p.date))
                rows.append(PanelRow(id: "date-" + p.text, symbol: "calendar", title: p.text,
                                     hint: "\(DateWords.iso(p.date)) · \(DateWords.describe(p.date))",
                                     trailing: rows.count == 1 ? "Tab" : nil) {
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
        if case .recentBoards = m.kind {
            hint = state.recentBoards.first.map { "上一站「\($0.title)」· \(relativeTime($0.at))" } ?? "还没有足迹（切换白板时会记下来）"
        } else if case .allTodos = m.kind {
            let due = state.todos.filter { ($0.daysLeft() ?? 1) <= 0 }.count
            hint = state.todos.isEmpty ? "没有正文以 @todo 开头的卡" : "\(state.todos.count) 条" + (due > 0 ? "，\(due) 条已到期" : "")
        } else if case .undo = m.kind, let label = state.undoLabel {
            hint = "撤回「\(label)」（Allume 自己的 ⌘Z 撤不掉 CLI 做的事）"
        }
        var title = m.title
        if case .openSelectedBoard = m.kind, let card = state.selectedCards.first, !card.title.isEmpty {
            title = "打开「\(card.title)」"
        }
        return PanelRow(id: m.id, symbol: m.spec.symbol, title: title, hint: hint) {
            switch m.kind {
            case .recentBoards: state.panelMode = .recentBoards
            case .allTodos: state.panelMode = .allTodos
            case .addTodo: state.panelMode = .addTodo
            default: Task { await runner.run(m.kind) }
            }
        }
    }

    private func boardRow(_ v: VisitTrail.Visit) -> PanelRow {
        PanelRow(id: v.boardId, symbol: "rectangle.on.rectangle", title: v.title.isEmpty ? "（无标题白板）" : v.title,
                 hint: relativeTime(v.at)) {
            Task { await runner.openBoard(id: v.boardId, title: v.title) }
        }
    }

    private func searchBoardRow(_ b: BoardRef) -> PanelRow {
        PanelRow(id: "b:" + b.id, symbol: "rectangle.on.rectangle", title: b.title.isEmpty ? "（无标题白板）" : b.title,
                 hint: b.path.isEmpty ? "workspace 首页" : b.path) {
            Task { await runner.openBoard(id: b.id, title: b.title) }
        }
    }

    private func todoRow(_ t: TodoItem) -> PanelRow { todoRow(t, idPrefix: "") }

    private func todoRow(_ t: TodoItem, idPrefix: String) -> PanelRow {
        let days = t.daysLeft()
        return PanelRow(id: idPrefix + t.cardId, symbol: (days ?? 1) <= 0 ? "exclamationmark.circle" : "circle",
                        title: t.label, hint: "白板：\(t.boardTitle)",
                        trailing: t.dueLabel, trailingIsUrgent: (days ?? 1) <= 0) {
            Task { await runner.openBoard(id: t.boardId, title: t.boardTitle) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchRow
            if listHeight > 0 {
                Divider()
                results
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { panelBackground }
        .onAppear { fieldFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .panelShown)) { _ in
            if !query.isEmpty { query = "" }
            if selectedIndex != 0 { selectedIndex = 0 }
            fieldFocused = true
            postHeight() // a preset selection (test hook) never changes `listHeight` on its own
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
        .onAppear { postHeight() }
        .onChange(of: listHeight) { _, _ in postHeight() }
    }

    private func postHeight() {
        NotificationCenter.default.post(name: .panelHeight, object: PanelMetrics.height(list: listHeight))
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
        HStack(spacing: 12) {
            if state.panelMode != .commands {
                Image(systemName: modeSymbol)
                    .font(.system(size: 18)).foregroundStyle(.secondary)
            } else if !state.selectedCardIds.isEmpty {
                CardStackView(cards: state.selectedCards, count: state.selectedCardIds.count)
            } else if state.selectionPending {
                CardStackPlaceholder()
            }
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular))
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
        }
        .padding(.horizontal, 14)
        .frame(height: PanelMetrics.searchRow)
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
        case .addTodo: return "plus.circle"
        default: return "clock.arrow.circlepath"
        }
    }

    /// With nothing selected the field just invites a command; the reason nothing was read
    /// (timeout, no Allume…) goes to the log, not in the user's face.
    private var placeholder: String {
        switch state.panelMode {
        case .recentBoards: return "筛选最近去过的白板…"
        case .allTodos: return "筛选待办…"
        case .addTodo: return "待办内容，加个日期：下周二 交房租"
        case .commands:
            if state.selectedCardIds.isEmpty { return "输入命令、白板或待办…" }
            if state.selectedCardIds.count == 1, let t = state.selectedCards.first?.title, !t.isEmpty { return "对「\(t)」做什么？" }
            return "对 \(state.selectedCardIds.count) 张卡做什么？排列、大小…"
        }
    }

    // MARK: - Results

    private var emptyText: String {
        switch state.panelMode {
        case .commands: return "没有匹配的命令、白板或待办"
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
                    if sections.allSatisfy({ $0.rows.isEmpty }) {
                        Text(emptyText).foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).frame(height: PanelMetrics.row)
                    }
                    ForEach(Array(sections.enumerated()), id: \.element.id) { si, section in
                        if let title = section.title {
                            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, 6)
                                .frame(height: PanelMetrics.header, alignment: .leading)
                                .id("h:" + section.id)
                        }
                        ForEach(Array(section.rows.enumerated()), id: \.element.id) { ri, r in
                            let i = firstIndex[si] + ri
                            ResultRow(row: r, selected: i == selectedIndex)
                                .frame(height: PanelMetrics.row)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedIndex = i; runSelected() }
                                .id(r.id)
                        }
                    }
                }
                .padding(8)
            }
            .frame(height: listHeight)
            .animation(.easeOut(duration: PanelMetrics.resizeDuration), value: listHeight)
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

    private var footer: some View {
        HStack(spacing: 5) {
            if state.panelMode == .addTodo {
                Text("添加待办").font(.caption).foregroundStyle(.tertiary)
            } else if state.panelMode != .commands {
                Text(state.panelMode == .allTodos ? "全部待办 · \(rows.count) 条" : "最近去过 · \(rows.count) 块白板")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if !state.status.isEmpty {
                Image(systemName: state.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(state.statusIsError ? Color.orange : Color.green)
                Text(state.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if !state.boardTitle.isEmpty {
                Text("白板：\(state.boardTitle)").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(footerKeys).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: PanelMetrics.footer)
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

private struct ResultRow: View {
    let row: PanelRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .frame(width: 22)
                .foregroundStyle(selected ? Color.white : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(row.hint).font(.caption).lineLimit(1)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer()
            if let t = row.trailing {
                Text(t).font(.caption.weight(.medium))
                    .foregroundStyle(selected ? Color.white : (row.trailingIsUrgent ? Color.orange : Color.secondary))
            }
            if selected { Text("⏎").font(.caption).foregroundStyle(Color.white.opacity(0.8)) }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Up to three overlapping cards with the count badge: the "what you selected" token.
struct CardStackView: View {
    let cards: [CardSummary]
    let count: Int

    /// How many faces the stack draws (and how many thumbnails are fetched per ⌘K).
    static let visible = 3
    private let size = CGSize(width: 60, height: 42)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(cards.prefix(Self.visible).enumerated().reversed()), id: \.element.id) { i, card in
                CardFace(card: card, size: size)
                    .offset(x: CGFloat(i) * 6, y: CGFloat(i) * -4)
            }
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accent, in: Capsule())
                    .offset(x: size.width - 10 + CGFloat(min(cards.count, Self.visible) - 1) * 6, y: -10)
            }
        }
        .frame(width: size.width + 14, height: size.height + 8, alignment: .bottomLeading)
        .padding(.top, 4)
    }
}

/// Stands where the card stack will be while the clipboard round trip is in flight (the panel
/// is already up), so the field does not jump right when the cards arrive 30–100 ms later.
/// Same footprint as `CardStackView`. Gone when nothing turns out to be selected.
private struct CardStackPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(width: 60, height: 42)
            .frame(width: 60 + 14, height: 42 + 8, alignment: .bottomLeading)
            .padding(.top, 4)
    }
}

/// One card in the stack. With a thumbnail the picture fills the card (aspect fill, rounded
/// clip) and the title sits on a translucent bar at the bottom; text/chain cards show the first
/// words of their body; everything else is the kind's icon plus the title.
private struct CardFace: View {
    let card: CardSummary
    let size: CGSize

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(nsColor: .windowBackgroundColor)
            if let img = card.thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                if !card.title.isEmpty {
                    Text(card.title)
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.45))
                }
            } else if !card.excerpt.isEmpty {
                Text(card.excerpt)
                    .font(.system(size: 7.5))
                    .lineLimit(4)
                    .foregroundStyle(.primary)
                    .padding(4)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(card.title.isEmpty ? "…" : card.title)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }
                .padding(5)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
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
