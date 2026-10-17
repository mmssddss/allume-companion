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
    static let listPadding: CGFloat = 16
    static let footer: CGFloat = 30
    static let maxRows = 8
    static func height(forRows n: Int) -> CGFloat {
        searchRow + 1 + CGFloat(max(1, min(n, maxRows))) * row + listPadding + footer
    }
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
/// and the matching rows below. ↑/↓ pick, ⏎ runs, Esc or ⌘K closes. Two rows are not commands
/// but lists ("最近去过", "全部待办"): ⏎ on them swaps the rows for that list (filtered by what
/// is typed), ⏎ on a list row jumps to its board, Esc or ⌫ on an empty field comes back.
struct CommandPanelView: View {
    @ObservedObject var state: AppState
    let runner: CommandRunner
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    private var matches: [CommandMatch] {
        CommandCatalog.matches(for: query).filter { m in
            !m.spec.needsSelection || !state.selectedCardIds.isEmpty || state.selectionPending
        }
    }

    private var rows: [PanelRow] {
        switch state.panelMode {
        case .commands: return matches.map(commandRow)
        case .recentBoards: return filtered(state.recentBoards.map(boardRow))
        case .allTodos: return filtered(state.todos.map(todoRow))
        case .addTodo: return [addTodoRow]
        }
    }

    /// The one row of the "添加待办" field: what will be added, where, and when it is due.
    private var addTodoRow: PanelRow {
        let raw = query // runSelected clears the field before the row runs
        let draft = TodoDraft.parse(raw)
        let board = runner.boardModel?.title ?? state.boardTitle
        let place = board.isEmpty ? "当前白板" : "「\(board)」"
        return PanelRow(id: "add-todo", symbol: "plus.circle",
                        title: draft.text.isEmpty ? "输入待办内容" : draft.text,
                        hint: draft.text.isEmpty ? "⏎ 贴到\(place)；末尾加日期设到期：明天 / 10-20 / 2026-10-20" : "⏎ 贴到\(place)",
                        trailing: draft.due.map { "到期 \($0)" }) {
            guard !draft.text.isEmpty else { return }
            Task { await runner.addTodo(raw) }
        }
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
        }
        return PanelRow(id: m.id, symbol: m.spec.symbol, title: m.title, hint: hint) {
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

    private func todoRow(_ t: TodoItem) -> PanelRow {
        let days = t.daysLeft()
        return PanelRow(id: t.cardId, symbol: (days ?? 1) <= 0 ? "exclamationmark.circle" : "circle",
                        title: t.label, hint: "白板：\(t.boardTitle)",
                        trailing: t.dueLabel, trailingIsUrgent: (days ?? 1) <= 0) {
            Task { await runner.openBoard(id: t.boardId, title: t.boardTitle) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchRow
            Divider()
            results
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
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onChange(of: state.panelMode) { _, _ in query = ""; selectedIndex = 0; fieldFocused = true }
        .onAppear { postHeight() }
        .onChange(of: rows.count) { _, _ in postHeight() }
    }

    private func postHeight() {
        NotificationCenter.default.post(name: .panelHeight, object: PanelMetrics.height(forRows: rows.count))
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
                .onKeyPress(.tab) { move(1); return .handled }
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
        case .addTodo: return "⏎ 添加 · Esc 返回"
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
        case .addTodo: return "待办内容，末尾可加日期：明天 / 10-20"
        case .commands: return state.selectedCardIds.isEmpty ? "输入命令…" : "对 \(state.selectedCardIds.count) 张卡做什么？排列、大小、撤销…"
        }
    }

    // MARK: - Results

    private var emptyText: String {
        switch state.panelMode {
        case .commands: return "没有匹配的命令"
        case .recentBoards: return state.recentBoards.isEmpty ? "还没有足迹：切换白板时会记下来" : "没有匹配的白板"
        case .allTodos: return state.todos.isEmpty ? "没有待办：正文第一行写 @todo 的文字卡会出现在这里" : "没有匹配的待办"
        case .addTodo: return ""
        }
    }

    /// The only scrolling part: at most `maxRows` rows are visible, the selected row is kept in view.
    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text(emptyText).foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).frame(height: PanelMetrics.row)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        ResultRow(row: r, selected: i == selectedIndex)
                            .frame(height: PanelMetrics.row)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedIndex = i; runSelected() }
                            .id(r.id)
                    }
                }
                .padding(8)
            }
            .frame(height: CGFloat(max(1, min(rows.count, PanelMetrics.maxRows))) * PanelMetrics.row + PanelMetrics.listPadding)
            .animation(.easeOut(duration: PanelMetrics.resizeDuration), value: rows.count)
            .onChange(of: selectedIndex) { _, i in
                if rows.indices.contains(i) { proxy.scrollTo(rows[i].id, anchor: nil) }
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
