import Foundation

/// Daily notes and projects (docs/DEVELOPMENT.md "日记与项目"). The companion keeps its own corner of the
/// workspace, a board titled `workspace-Companion` on the root board:
///
///     workspace-Companion
///     ├─ Daily Notes › 2026 › 2026-10 › 2026-10-17   (a year is four rows of quarters; a month is
///     │                                               a calendar under a 一 … 日 / Mon … Sun header)
///     └─ Projects › Todo / Doing / Done              (project-<name> boards, newest top left)
///
/// Every board here is created by the companion and its id is kept in companion.json, so it
/// never mistakes a board of the user's for one of its own. Changing a project's status only
/// acts on `project-` boards mounted on our Todo / Doing / Done, checked against a fresh read.

/// Where a project sits: one of the three boards under Projects.
enum ProjectStatus: String, Codable, CaseIterable {
    case todo, doing, done

    var title: String {
        switch self {
        case .todo: return "Todo"
        case .doing: return "Doing"
        case .done: return "Done"
        }
    }
}

/// 设置 → 日记与项目.
enum CompanionSettings {
    private static let d = UserDefaults.standard
    static func registerDefaults() {
        d.register(defaults: ["companion.weekStartsMonday": true, "companion.newProjectStatus": "todo",
                              "companion.projectColumns": 6, "companion.headerLanguage": "zh"])
    }
    /// Language the weekday headers on the month boards are in ("zh" / "en"); every version
    /// before English headers wrote Chinese ones.
    static var headerLanguage: String {
        get { d.string(forKey: "companion.headerLanguage") ?? "zh" }
        set { d.set(newValue, forKey: "companion.headerLanguage") }
    }
    static var weekStartsMonday: Bool {
        get { d.bool(forKey: "companion.weekStartsMonday") }
        set { d.set(newValue, forKey: "companion.weekStartsMonday") }
    }
    static var newProjectStatus: ProjectStatus {
        get { ProjectStatus(rawValue: d.string(forKey: "companion.newProjectStatus") ?? "") ?? .todo }
        set { d.set(newValue.rawValue, forKey: "companion.newProjectStatus") }
    }
    static let columnRange = 3...8
    static var projectColumns: Int {
        get { min(max(d.integer(forKey: "companion.projectColumns"), columnRange.lowerBound), columnRange.upperBound) }
        set { d.set(newValue, forKey: "companion.projectColumns") }
    }
}

/// Titles and positions. Pure Foundation, so it can be checked with a plain `swiftc` build.
enum CompanionLayout {
    static let rootTitle = "workspace-Companion"
    static let dailyTitle = "Daily Notes"
    static let projectsTitle = "Projects"
    static let projectPrefix = "project-"
    /// Weekday header, Monday first, in each board language.
    static let weekdayNames = ["一", "二", "三", "四", "五", "六", "日"]
    static let englishWeekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// "en" or "zh": the language the UI runs in (System Settings, per app or system-wide),
    /// which is also what the companion writes on the boards.
    static var boardLanguage: String {
        (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh") ? "zh" : "en"
    }

    static func weekdayNames(_ language: String) -> [String] { language == "zh" ? weekdayNames : englishWeekdayNames }

    /// A header card's text in `language` ("一" → "Mon"); nil when `text` is no weekday header.
    static func weekdayName(translating text: String, to language: String) -> String? {
        guard let i = weekdayNames.firstIndex(of: text) ?? englishWeekdayNames.firstIndex(of: text) else { return nil }
        return weekdayNames(language)[i]
    }

    /// A sub-board card comes out 200×150 and its title is drawn ~25pt above the frame, so rows
    /// leave room for it. A text card is at least 170×40.
    static let pitchX = 240.0
    static let pitchY = 210.0
    static let origin = 80.0
    static let headerHeight = 40.0
    /// Between the notes stacked down a day board ("记到某天"); they have no title band.
    static let noteGap = 24.0

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    typealias Slot = (x: Double, y: Double)

    /// The i-th board of a row: Daily Notes and Projects, the years, Todo / Doing / Done.
    static func rowSlot(_ i: Int) -> Slot { (origin + Double(i) * pitchX, origin) }

    static func gridSlot(_ i: Int, columns: Int) -> Slot {
        let c = max(1, columns)
        return (origin + Double(i % c) * pitchX, origin + Double(i / c) * pitchY)
    }

    /// Year board: three months a row, one row per quarter.
    static func monthSlot(_ month: Int) -> Slot { gridSlot(month - 1, columns: 3) }

    /// The 一 … 日 (Mon … Sun) text cards along the top of a month board (170 wide, centred over a column).
    static func weekdayHeader(mondayFirst: Bool, language: String) -> [(text: String, x: Double, y: Double)] {
        let all = weekdayNames(language)
        let names = mondayFirst ? all : [all[6]] + all.dropLast()
        return names.enumerated().map { i, n in (n, origin + Double(i) * pitchX + 15, origin) }
    }

    /// Month board: each day in its weekday's column, one row per week, under the header.
    static func daySlots(year: Int, month: Int, mondayFirst: Bool) -> [(day: Int, x: Double, y: Double)] {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let weekday = calendar.component(.weekday, from: first) // 1 = Sunday
        let lead = mondayFirst ? (weekday + 5) % 7 : weekday - 1
        let top = origin + headerHeight + 50
        return (1...days).map { d in
            let cell = lead + d - 1
            return (d, origin + Double(cell % 7) * pitchX, top + Double(cell / 7) * pitchY)
        }
    }

    static func yearTitle(_ year: Int) -> String { String(format: "%04d", year) }
    static func monthTitle(_ year: Int, _ month: Int) -> String { String(format: "%04d-%02d", year, month) }
    static func dayTitle(_ year: Int, _ month: Int, _ day: Int) -> String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// The day `offset` days from today (-1 yesterday, 1 tomorrow).
    static func today(offset: Int = 0, _ now: Date = Date()) -> (year: Int, month: Int, day: Int) {
        let date = calendar.date(byAdding: .day, value: offset, to: now) ?? now
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }

    /// The day of a `YYYY-MM-DD` string; nil when it is not one or no such day exists.
    static func day(iso: String) -> (year: Int, month: Int, day: Int)? {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let date = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])),
              calendar.component(.day, from: date) == p[2] else { return nil }
        return (p[0], p[1], p[2])
    }

    /// "周六" ("Sat" in English) for a date: a label for the panel, never written to a board.
    static func weekdayName(year: Int, month: Int, day: Int) -> String {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return "" }
        let w = calendar.component(.weekday, from: date) // 1 = Sunday
        return DateWords.weekdayLabel(DateWords.weekdayNames[(w + 5) % 7])
    }

    /// `project-<name>`; a typed prefix is not doubled. Empty when there is no name.
    static func projectTitle(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix(projectPrefix) { name = String(name.dropFirst(projectPrefix.count)) }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "" : projectPrefix + name
    }

    static func isProjectTitle(_ title: String?) -> Bool {
        guard let t = title?.lowercased(), t.hasPrefix(projectPrefix) else { return false }
        return t.count > projectPrefix.count
    }
}

/// The ids of the companion's own boards in one workspace (companion.json, keyed by workspace).
struct CompanionRegistry: Codable {
    var root: String?
    var daily: String?
    var projects: String?
    /// ProjectStatus raw value → board id of Todo / Doing / Done.
    var lists: [String: String] = [:]
    /// Title ("2026", "2026-10", "2026-10-17") → board id.
    var years: [String: String] = [:]
    var months: [String: String] = [:]
    var days: [String: String] = [:]
    /// Months whose header and every day board exist.
    var filledMonths: Set<String> = []
    /// Project board id → the list it was last seen on.
    var projectBoards: [String: ProjectStatus] = [:]
}

@MainActor
final class CompanionStore {
    static let fileURL = BoardIndex.fileURL.deletingLastPathComponent().appendingPathComponent("companion.json")

    private var registries: [String: CompanionRegistry] = [:]
    /// The workspace the companion last worked in (looked up once a launch).
    var workspace: (id: String, root: String)?
    /// The background fill of a year's months and days; one at a time.
    var fill: Task<Void, Never>?
    /// The background rewrite of the weekday headers (`relabelWeekdaysIfNeeded`).
    var relabel: Task<Void, Never>?

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let r = try? JSONDecoder().decode([String: CompanionRegistry].self, from: data) {
            registries = r
        }
    }

    func registry(_ workspace: String) -> CompanionRegistry { registries[workspace] ?? CompanionRegistry() }

    func update(_ workspace: String, _ change: (inout CompanionRegistry) -> Void) {
        var r = registry(workspace)
        change(&r)
        registries[workspace] = r
        save()
    }

    /// Every month board across workspaces, by title (workspace-qualified when titles repeat).
    var allMonths: [String: String] {
        registries.reduce(into: [:]) { acc, w in for (t, id) in w.value.months { acc[acc[t] == nil ? t : "\(w.key) \(t)"] = id } }
    }

    /// Every known project across workspaces, for listing the status commands.
    var allProjects: [String: ProjectStatus] {
        registries.values.reduce(into: [:]) { acc, r in acc.merge(r.projectBoards) { a, _ in a } }
    }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(registries) else { return }
        do { try data.write(to: Self.fileURL, options: .atomic) }
        catch { Log.info("companion: save failed: \(error.localizedDescription)") }
    }
}

// MARK: - Commands

extension CommandRunner {
    private struct WorkspaceRow: Decodable { let id: String; let rootBoardId: String? }

    /// Our boards every command needs, checked to still be mounted where we put them.
    private struct Base {
        let workspace: String
        let daily: String
        let lists: [ProjectStatus: String]
    }

    /// One CLI call: in front, logged to the panel like every command; for the background fill,
    /// only to the log file.
    private func call(_ args: [String], background: Bool) async -> AllumeCLI.Result {
        if !background { return await exec(args, showStdout: false) }
        let r = await AllumeCLI.run(args, background: true)
        if !r.ok { Log.info("companion: failed \(AllumeCLI.render(args)): \(r.stderr.split(separator: "\n").first ?? "")") }
        return r
    }

    private func rows(of board: String, subBoardsOnly: Bool = false, background: Bool = false) async -> [BoardCard]? {
        var args = ["board-content", board, "--format", "json"]
        if subBoardsOnly { args += ["--kinds", "subBoard"] }
        let r = await call(args, background: background)
        return r.ok ? BoardCard.decodeRows(r.stdout) : nil
    }

    /// The workspace the current board is in (with several, the one above it in the index;
    /// else the first), cached for the launch.
    private func companionWorkspace() async -> (id: String, root: String)? {
        if let w = companion.workspace { return w }
        let r = await exec(["list-workspaces", "--format", "json"], showStdout: false)
        guard r.ok else { return nil }
        let all = ((try? JSONDecoder().decode([WorkspaceRow].self, from: Data(r.stdout.utf8))) ?? [])
            .compactMap { w in w.rootBoardId.map { (id: w.id, root: $0) } }
        var above = Set<String>()
        var next = boardModel?.boardId
        while let id = next, above.insert(id).inserted { next = boardModel?.index.parentId(of: id) }
        guard let w = all.first(where: { above.contains($0.root) }) ?? all.first else {
            state.setStatus(String(localized: "list-workspaces 没有返回 workspace"), error: true)
            return nil
        }
        companion.workspace = w
        return w
    }

    /// A new board titled `title`, mounted on `parent` at `slot`; returns the new card's row.
    private func createBoard(_ title: String, on parent: String, at slot: CompanionLayout.Slot,
                             workspace: String, background: Bool = false) async -> BoardCard? {
        let made = await call(["board-create", "-w", workspace, "--title", title, "--format", "id"], background: background)
        let id = made.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard made.ok, !id.isEmpty else { return nil }
        let card = await call(["card-create", "--parent", parent, "--document", id,
                               "--x", Self.num(slot.x), "--y", Self.num(slot.y), "--format", "json"], background: background)
        guard card.ok, let row = BoardCard.decodeRows(card.stdout).first else { return nil }
        boardModel?.index.learn(title: title, id: id, parentId: parent)
        return row
    }

    /// Our sub-board `title` on our board `parent`: the one registered as `known` while it is
    /// still mounted there, else one mounted there with exactly that title, else a new one.
    private func ensureChild(_ title: String, in parent: String, mounted: [BoardCard], known: String?,
                             workspace: String, background: Bool = false,
                             slot: () async -> CompanionLayout.Slot) async -> String? {
        if let known, mounted.contains(where: { $0.document?.id == known }) { return known }
        if let hit = mounted.first(where: { $0.kind == "subBoard" && ($0.document?.title ?? $0.title) == title })?.document?.id {
            return hit
        }
        return await createBoard(title, on: parent, at: await slot(), workspace: workspace, background: background)?.document?.id
    }

    /// workspace-Companion with Daily Notes, Projects and Todo / Doing / Done, created where
    /// missing. Three reads when everything is there.
    private func ensureBase() async -> Base? {
        guard let ws = await companionWorkspace() else { return nil }
        var reg = companion.registry(ws.id)
        defer { companion.update(ws.id) { $0 = reg } }
        guard let onRoot = await rows(of: ws.root, subBoardsOnly: true) else { return nil }
        let root = await ensureChild(CompanionLayout.rootTitle, in: ws.root, mounted: onRoot, known: reg.root, workspace: ws.id) {
            // Right of everything on the root board, so nothing of the user's is covered.
            let all = await self.rows(of: ws.root) ?? []
            let right = all.map { $0.frame.x + $0.frame.width }.max()
            return (right.map { $0 + 80 } ?? CompanionLayout.origin, all.map(\.frame.y).min() ?? CompanionLayout.origin)
        }
        guard let root else { return nil }
        reg.root = root
        guard let inRoot = await rows(of: root, subBoardsOnly: true) else { return nil }
        guard let daily = await ensureChild(CompanionLayout.dailyTitle, in: root, mounted: inRoot, known: reg.daily,
                                            workspace: ws.id, slot: { CompanionLayout.rowSlot(0) }) else { return nil }
        reg.daily = daily
        guard let projects = await ensureChild(CompanionLayout.projectsTitle, in: root, mounted: inRoot, known: reg.projects,
                                               workspace: ws.id, slot: { CompanionLayout.rowSlot(1) }) else { return nil }
        reg.projects = projects
        guard let inProjects = await rows(of: projects, subBoardsOnly: true) else { return nil }
        var lists: [ProjectStatus: String] = [:]
        for (i, s) in ProjectStatus.allCases.enumerated() {
            guard let id = await ensureChild(s.title, in: projects, mounted: inProjects, known: reg.lists[s.rawValue],
                                             workspace: ws.id, slot: { CompanionLayout.rowSlot(i) }) else { return nil }
            lists[s] = id
            reg.lists[s.rawValue] = id
        }
        state.boards = boardModel?.index.refs ?? state.boards
        return Base(workspace: ws.id, daily: daily, lists: lists)
    }

    // MARK: Daily notes

    /// "今天" / "昨天" / "明天": opens that day's board under Daily Notes › year › month, creating
    /// what is missing, then fills in the rest of that year (every month, every day) in the
    /// background. With the board already there this is one read and the jump.
    func openDay(offset: Int) async {
        guard !state.isRunning else { return }
        state.requestHidePanel?()
        state.isRunning = true
        defer { state.isRunning = false }
        state.setStatus("")
        let t = CompanionLayout.today(offset: offset)
        guard let ws = await companionWorkspace(), let dayId = await ensureDay(t, workspace: ws.id) else { return }
        await openBoard(id: dayId, title: CompanionLayout.dayTitle(t.year, t.month, t.day))
        fillYear(t.year)
    }

    /// "记到某天": sticks an @todo card on that day's board (the date typed at the start or end,
    /// else today) without leaving the current board; the day's board is created like `openDay`.
    /// The card goes under the cards already there, at their left edge, so a day's notes read
    /// top to bottom in the order they were added. The marker carries the day as its due date,
    /// so it is listed in 全部待办 and reminded like any other dated todo.
    func addTodoToDay(_ raw: String) async {
        var draft = TodoDraft.parse(raw)
        guard !draft.text.isEmpty, !state.isRunning else { return }
        let t = draft.due.flatMap(CompanionLayout.day(iso:)) ?? CompanionLayout.today()
        let dayTitle = CompanionLayout.dayTitle(t.year, t.month, t.day)
        draft.due = dayTitle
        state.requestHidePanel?()
        state.isRunning = true
        defer { state.isRunning = false }
        state.setStatus("")
        guard let ws = await companionWorkspace(), let dayId = await ensureDay(t, workspace: ws.id),
              let onDay = await rows(of: dayId) else { return }
        let x = onDay.map(\.frame.x).min() ?? CompanionLayout.origin
        let y = onDay.map { $0.frame.y + $0.frame.height }.max().map { $0 + CompanionLayout.noteGap } ?? CompanionLayout.origin
        let r = await exec(["card-add", "--parent", dayId, "--text", draft.body,
                            "--x", Self.num(x.rounded()), "--y", Self.num(y.rounded()), "--format", "json"], showStdout: false)
        guard r.ok else { return }
        state.setStatus(String(localized: "已记到 \(dayTitle) \(CompanionLayout.weekdayName(year: t.year, month: t.month, day: t.day))：\(draft.text)"))
        // Read the day back so the todo list and reminders have it now, and so the todo scan
        // stops skipping the board as empty before the next crawl.
        if let after = await rows(of: dayId, background: true) {
            boardModel?.index.noteCardCount(after.count, of: dayId)
            onBoardRead?(dayId, dayTitle, after)
        }
        if boardModel?.boardId == dayId, let model = boardModel { Task { await model.refresh(reason: "after add todo") } }
        fillYear(t.year)
    }

    /// That day's board under Daily Notes › year › month, creating what is missing. With it
    /// already there this is one read (the month board, to check the day is still mounted).
    private func ensureDay(_ t: (year: Int, month: Int, day: Int), workspace ws: String) async -> String? {
        let dayTitle = CompanionLayout.dayTitle(t.year, t.month, t.day)
        let monthTitle = CompanionLayout.monthTitle(t.year, t.month)
        let reg = companion.registry(ws)
        if let dayId = reg.days[dayTitle], let monthId = reg.months[monthTitle],
           let onMonth = await rows(of: monthId, subBoardsOnly: true), onMonth.contains(where: { $0.document?.id == dayId }) {
            return dayId
        }
        state.appendLog(String(localized: "准备 daily note：\(dayTitle)"))
        let slot = CompanionLayout.daySlots(year: t.year, month: t.month, mondayFirst: CompanionSettings.weekStartsMonday)
            .first { $0.day == t.day }.map { (x: $0.x, y: $0.y) } ?? CompanionLayout.rowSlot(0)
        guard let base = await ensureBase(),
              let yearId = await ensureYear(t.year, base: base),
              let monthId = await ensureMonth(t.year, t.month, yearId: yearId, workspace: base.workspace),
              let onMonth = await rows(of: monthId, subBoardsOnly: true),
              let dayId = await ensureChild(dayTitle, in: monthId, mounted: onMonth, known: companion.registry(ws).days[dayTitle],
                                            workspace: ws, slot: { slot }) else {
            if state.status.isEmpty { state.setStatus(String(localized: "没能建好 \(dayTitle) 的白板，看日志"), error: true) }
            return nil
        }
        companion.update(ws) { $0.days[dayTitle] = dayId }
        return dayId
    }

    /// "本月": opens this month's calendar board, creating the path to it like `openDay`.
    func openThisMonth() async {
        guard !state.isRunning else { return }
        state.requestHidePanel?()
        state.isRunning = true
        defer { state.isRunning = false }
        state.setStatus("")
        let t = CompanionLayout.today()
        let monthTitle = CompanionLayout.monthTitle(t.year, t.month)
        guard let ws = await companionWorkspace() else { return }
        let reg = companion.registry(ws.id)
        if let monthId = reg.months[monthTitle], let yearId = reg.years[CompanionLayout.yearTitle(t.year)],
           let onYear = await rows(of: yearId, subBoardsOnly: true), onYear.contains(where: { $0.document?.id == monthId }) {
            await openBoard(id: monthId, title: monthTitle)
            fillYear(t.year)
            return
        }
        state.appendLog(String(localized: "准备月白板：\(monthTitle)"))
        guard let base = await ensureBase(),
              let yearId = await ensureYear(t.year, base: base),
              let monthId = await ensureMonth(t.year, t.month, yearId: yearId, workspace: base.workspace) else {
            if state.status.isEmpty { state.setStatus(String(localized: "没能建好 \(monthTitle) 的白板，看日志"), error: true) }
            return
        }
        await openBoard(id: monthId, title: monthTitle)
        fillYear(t.year)
    }

    private func ensureYear(_ year: Int, base: Base, background: Bool = false) async -> String? {
        let title = CompanionLayout.yearTitle(year)
        guard let onDaily = await rows(of: base.daily, subBoardsOnly: true, background: background) else { return nil }
        let years = onDaily.filter { ($0.document?.title ?? $0.title ?? "").count == 4 }.count
        let id = await ensureChild(title, in: base.daily, mounted: onDaily, known: companion.registry(base.workspace).years[title],
                                   workspace: base.workspace, background: background, slot: { CompanionLayout.rowSlot(years) })
        if let id { companion.update(base.workspace) { $0.years[title] = id } }
        return id
    }

    private func ensureMonth(_ year: Int, _ month: Int, yearId: String, workspace: String,
                             mounted: [BoardCard]? = nil, background: Bool = false) async -> String? {
        let title = CompanionLayout.monthTitle(year, month)
        var onYear = mounted
        if onYear == nil { onYear = await rows(of: yearId, subBoardsOnly: true, background: background) }
        guard let onYear else { return nil }
        let id = await ensureChild(title, in: yearId, mounted: onYear, known: companion.registry(workspace).months[title],
                                   workspace: workspace, background: background, slot: { CompanionLayout.monthSlot(month) })
        if let id { companion.update(workspace) { $0.months[title] = id } }
        return id
    }

    /// Every month of `year` with its header and day boards, in the background (~700 CLI calls
    /// for a whole year the first time, a few at once; nothing for months already filled).
    func fillYear(_ year: Int) {
        guard companion.fill == nil else { return }
        companion.fill = Task { @MainActor in
            defer { companion.fill = nil }
            guard let ws = await companionWorkspace() else { return }
            let reg = companion.registry(ws.id)
            let pending = (1...12).filter { !reg.filledMonths.contains(CompanionLayout.monthTitle(year, $0)) }
            guard !pending.isEmpty, let yearId = reg.years[CompanionLayout.yearTitle(year)],
                  let onYear = await rows(of: yearId, subBoardsOnly: true, background: true) else { return }
            Log.info("companion: filling \(pending.count) month(s) of \(year)")
            let t0 = Date()
            for month in pending {
                guard let monthId = await ensureMonth(year, month, yearId: yearId, workspace: ws.id, mounted: onYear, background: true) else { continue }
                await fillMonth(year, month, monthId: monthId, workspace: ws.id)
            }
            Log.info("companion: \(year) filled in \(Int(Date().timeIntervalSince(t0))) s")
        }
    }

    /// The weekday header and every day board of one month, whatever is missing.
    private func fillMonth(_ year: Int, _ month: Int, monthId: String, workspace: String) async {
        let title = CompanionLayout.monthTitle(year, month)
        guard let onMonth = await rows(of: monthId, background: true) else { return }
        let mondayFirst = CompanionSettings.weekStartsMonday
        var ok = true
        let hasHeader = onMonth.contains {
            $0.kind == "text" && CompanionLayout.weekdayName(translating: ($0.document?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines), to: "en") != nil
        }
        if !hasHeader {
            for h in CompanionLayout.weekdayHeader(mondayFirst: mondayFirst, language: CompanionLayout.boardLanguage) {
                let r = await call(["card-add", "--parent", monthId, "--text", h.text,
                                    "--x", Self.num(h.x), "--y", Self.num(h.y), "--format", "id"], background: true)
                if !r.ok { ok = false }
            }
        }
        let have = Dictionary(onMonth.compactMap { row -> (String, String)? in
            guard row.kind == "subBoard", let id = row.document?.id else { return nil }
            return ((row.document?.title ?? row.title ?? ""), id)
        }, uniquingKeysWith: { a, _ in a })
        let missing = CompanionLayout.daySlots(year: year, month: month, mondayFirst: mondayFirst).filter { slot in
            let t = CompanionLayout.dayTitle(year, month, slot.day)
            if let id = have[t] { companion.update(workspace) { $0.days[t] = id }; return false }
            return true
        }
        // A few at a time: each day is two calls in a row (board-create, card-create).
        let limit = 3
        for start in stride(from: 0, to: missing.count, by: limit) {
            let batch = Array(missing[start..<min(start + limit, missing.count)])
            let made = await withTaskGroup(of: (String, String?).self) { group in
                for slot in batch {
                    let t = CompanionLayout.dayTitle(year, month, slot.day)
                    group.addTask { @MainActor in
                        (t, await self.createBoard(t, on: monthId, at: (slot.x, slot.y), workspace: workspace, background: true)?.document?.id)
                    }
                }
                var out: [(String, String?)] = []
                for await x in group { out.append(x) }
                return out
            }
            for (t, id) in made {
                if let id { companion.update(workspace) { $0.days[t] = id } } else { ok = false }
            }
        }
        if ok { companion.update(workspace) { $0.filledMonths.insert(title) } }
        Log.info("companion: \(title) \(ok ? "filled" : "partly filled") (\(missing.count) day boards created\(hasHeader ? "" : ", header added"))")
    }

    // MARK: Board language

    /// Puts the weekday headers of every month board in the UI language after it changed
    /// (System Settings; takes effect at launch): each header card whose text is a weekday in
    /// the other language is `note-update`d in place, so position and size stay. Runs in the
    /// background once Allume is up; the language is remembered only when every month board
    /// was done, so a run that failed (Allume quit, CLI read-only) is repeated next time.
    func relabelWeekdaysIfNeeded() {
        let language = CompanionLayout.boardLanguage
        guard CompanionSettings.headerLanguage != language, companion.relabel == nil else { return }
        companion.relabel = Task { @MainActor in
            defer { companion.relabel = nil }
            let months = companion.allMonths
            Log.info("companion: weekday headers \(CompanionSettings.headerLanguage) → \(language) on \(months.count) month board(s)")
            let t0 = Date()
            var ok = true, changed = 0
            for (title, id) in months.sorted(by: { $0.key < $1.key }) {
                guard let onMonth = await rows(of: id, background: true) else { ok = false; continue }
                for row in onMonth where row.kind == "text" {
                    let text = (row.document?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let doc = row.document?.id, let target = CompanionLayout.weekdayName(translating: text, to: language),
                          target != text else { continue }
                    if await call(["note-update", "--document-id", doc, "--body", target, "--format", "id"], background: true).ok {
                        changed += 1
                    } else {
                        ok = false
                        Log.info("companion: \(title) header \"\(text)\" not updated")
                    }
                }
            }
            if ok { CompanionSettings.headerLanguage = language }
            Log.info("companion: \(changed) weekday header card(s) rewritten in \(Int(Date().timeIntervalSince(t0))) s\(ok ? "" : "; incomplete, will retry")")
        }
    }

    // MARK: Projects

    /// What the status commands act on: the selected cards that are known projects, or else the
    /// board the user is on when it is one. `fromBoard` says which.
    func projectTargets() -> (items: [(id: String, title: String, status: ProjectStatus)], fromBoard: Bool) {
        let known = state.projects
        let picked = state.selectedCards.compactMap { c -> (String, String, ProjectStatus)? in
            guard c.kind == "subBoard", let d = c.documentId, let s = known[d] else { return nil }
            return (d, c.title, s)
        }
        if !picked.isEmpty { return (picked.map { (id: $0.0, title: $0.1, status: $0.2) }, false) }
        if let id = boardModel?.boardId, let s = known[id] {
            return ([(id: id, title: boardModel?.title ?? "", status: s)], true)
        }
        return ([], false)
    }

    /// The project cards on Todo / Doing / Done as they are now; also refreshes what the
    /// companion knows about where each project is.
    private func readLists(_ base: Base) async -> [ProjectStatus: [BoardCard]]? {
        var out: [ProjectStatus: [BoardCard]] = [:]
        for (s, id) in base.lists {
            guard let r = await rows(of: id) else { return nil }
            out[s] = r
        }
        var map: [String: ProjectStatus] = [:]
        for (s, list) in out {
            for row in list where Self.isProject(row) { if let d = row.document?.id { map[d] = s } }
        }
        companion.update(base.workspace) { $0.projectBoards = map }
        state.projects = companion.allProjects
        return out
    }

    private static func isProject(_ row: BoardCard) -> Bool {
        row.kind == "subBoard" && CompanionLayout.isProjectTitle(row.document?.title ?? row.title)
    }

    /// Lays the project cards of one list out as a grid, newest first (the card id grows with
    /// creation, and a card moved here is new). Other cards on the list are not touched.
    /// Returns the `card-move` commands that put the moved cards back.
    private func relayout(_ list: [BoardCard]) async -> [[String]] {
        let projects = list.filter(Self.isProject).sorted { Self.idSuffix($0.id) > Self.idSuffix($1.id) }
        let columns = CompanionSettings.projectColumns
        var back: [[String]] = []
        for (i, card) in projects.enumerated() {
            let s = CompanionLayout.gridSlot(i, columns: columns)
            guard abs(card.frame.x - s.x) > 0.5 || abs(card.frame.y - s.y) > 0.5 else { continue }
            if await exec(["card-move", "--id", card.id, "--x", Self.num(s.x), "--y", Self.num(s.y)], showStdout: false).ok {
                back.append(moveBack(card.id, to: card.frame))
            }
        }
        return back
    }

    /// "新建项目": a `project-<name>` board on the list set in 设置 (Todo by default), first in
    /// its grid. Undo takes the card off again.
    func addProject(_ raw: String) async {
        let title = CompanionLayout.projectTitle(raw)
        guard !title.isEmpty, !state.isRunning else { return }
        state.requestHidePanel?()
        state.isRunning = true
        defer { state.isRunning = false }
        state.setStatus("")
        let status = CompanionSettings.newProjectStatus
        guard let base = await ensureBase(), let lists = await readLists(base),
              let listId = base.lists[status], let card = await createBoard(title, on: listId, at: CompanionLayout.gridSlot(0, columns: 1),
                                                                             workspace: base.workspace),
              let docId = card.document?.id else {
            if state.status.isEmpty { state.setStatus(String(localized: "没能新建「\(title)」，看日志"), error: true) }
            return
        }
        let back = await relayout((lists[status] ?? []) + [card])
        companion.update(base.workspace) { $0.projectBoards[docId] = status }
        state.projects = companion.allProjects
        state.boards = boardModel?.index.refs ?? state.boards
        let ws = base.workspace
        undoEntry = UndoEntry(label: String(localized: "新建「\(title)」"), commands: [["delete", card.id]] + back) { [weak self] in
            guard let self else { return }
            self.companion.update(ws) { $0.projectBoards[docId] = nil }
            self.state.projects = self.companion.allProjects
        }
        state.setStatus(String(localized: "已在 \(status.title) 新建「\(title)」"))
        if let boardModel { Task { await boardModel.refresh(reason: "after add project") } }
    }

    /// Moves the targets (`projectTargets`) to `target`: the board is mounted on the target list
    /// and its old card deleted (the board itself, with everything on it, is the same document),
    /// then both lists are laid out again. Only `project-` boards found on our three lists in a
    /// fresh read are moved. Undo deletes the new cards, undeletes the old ones and moves the
    /// rest back.
    func moveProjects(to target: ProjectStatus) async {
        let (targets, fromBoard) = projectTargets()
        guard !state.isRunning else { return }
        guard !targets.isEmpty else {
            state.setStatus(String(localized: "没有选中 project：只有 Projects 里 project- 开头的白板能改状态"), error: true)
            return
        }
        state.isRunning = true
        defer { state.isRunning = false }
        state.setStatus("")
        guard let base = await ensureBase(), var lists = await readLists(base), let targetList = base.lists[target] else {
            if state.status.isEmpty { state.setStatus(String(localized: "读不到 Projects 的三块白板，看日志"), error: true) }
            return
        }
        let before = state.projects
        var created: [String] = [], removed: [String] = [], moved: [String] = []
        var touched: Set<ProjectStatus> = [target]
        for t in targets {
            guard let (from, card) = ProjectStatus.allCases.lazy.compactMap({ s in
                lists[s]?.first(where: { Self.isProject($0) && $0.document?.id == t.id }).map { (s, $0) }
            }).first else {
                state.appendLog(String(localized: "「\(t.title)」不在 Projects 的 Todo / Doing / Done 里，没动"))
                continue
            }
            guard from != target else { continue }
            let r = await exec(["card-create", "--parent", targetList, "--document", t.id, "--x", Self.num(CompanionLayout.origin),
                                "--y", Self.num(CompanionLayout.origin), "--format", "json"], showStdout: false)
            guard r.ok, let row = BoardCard.decodeRows(r.stdout).first else { continue }
            guard await exec(["delete", card.id], showStdout: false).ok else {
                await exec(["delete", row.id], showStdout: false) // keep it in one place
                continue
            }
            lists[from]?.removeAll { $0.id == card.id }
            lists[target, default: []].append(row)
            created.append(row.id); removed.append(card.id); moved.append(t.title)
            touched.insert(from)
            boardModel?.index.learn(title: t.title, id: t.id, parentId: targetList)
        }
        guard !moved.isEmpty else {
            if state.status.isEmpty { state.setStatus(String(localized: "已经在 \(target.title) 里了")) }
            return
        }
        var back: [[String]] = []
        for s in ProjectStatus.allCases where touched.contains(s) { back += await relayout(lists[s] ?? []) }
        companion.update(base.workspace) { reg in for t in targets where moved.contains(t.title) { reg.projectBoards[t.id] = target } }
        state.projects = companion.allProjects
        let what = moved.count == 1 ? String(localized: "「\(moved[0])」") : String(localized: "\(moved.count) 个 project")
        let label = target == .done ? String(localized: "完成\(what)") : String(localized: "把\(what)移到 \(target.title)")
        let ws = base.workspace
        undoEntry = UndoEntry(label: label, commands: created.map { ["delete", $0] } + removed.map { ["undelete", $0] } + back) { [weak self] in
            guard let self else { return }
            self.companion.update(ws) { reg in for t in targets { if let s = before[t.id] { reg.projectBoards[t.id] = s } } }
            self.state.projects = self.companion.allProjects
        }
        state.setStatus(target == .done ? String(localized: "已完成\(what)，移到 Done") : String(localized: "已把\(what)移到 \(target.title)"))
        if fromBoard { state.appendLog(String(localized: "当前白板已移到 \(target.title)")) }
        if let boardModel { Task { await boardModel.refresh(reason: "after move project") } }
    }
}
