import Foundation

/// The commands the Spotlight-style panel can run, with multilingual aliases and argument parsing.
/// Pure Swift (no AppKit) so it can be unit-tested with a plain `swiftc` build.
/// How cards are ordered inside a layout. `visual` = reading order (by y, then x).
struct SortOrder: Equatable {
    enum Key: String { case visual, title, created }
    var key: Key = .visual
    var reversed = false

    var label: String? {
        switch (key, reversed) {
        case (.visual, false): return nil
        case (.visual, true): return String(localized: "逆序")
        case (.title, false): return String(localized: "按标题")
        case (.title, true): return String(localized: "按标题逆序")
        case (.created, false): return String(localized: "按时间")
        case (.created, true): return String(localized: "按时间逆序")
        }
    }
}

enum CommandKind: Equatable {
    case gather(layout: String, columns: Int, order: SortOrder)   // card-gather --layout grid|row|column
    case resize(width: Int, height: Int)        // card-move --width --height on each card (one of `sizes`)
    case undo
    /// The two navigation lists; the panel view switches into them instead of calling the runner.
    case recentBoards
    case allTodos
    /// Jump to the root board of the current workspace (the first crumb of Allume's breadcrumb).
    case home
    /// Switches the panel into a text field whose ⏎ sticks a @todo card on the current board.
    case addTodo
    /// Same field, but ⏎ sticks the @todo card on that day's daily note (default today).
    case addToDay
    /// Jump into the one selected sub-board card.
    case openSelectedBoard
    /// Open (creating if needed) the daily note `offset` days from today: 0 today, -1, 1.
    case day(offset: Int)
    /// Open (creating if needed) this month's calendar board.
    case thisMonth
    /// Switches the panel into a text field whose ⏎ creates a `project-` board.
    case addProject
    /// Move the selected projects (or the current project board) to Todo / Doing / Done.
    case moveProjects(ProjectStatus)
}

/// The panel's sections, in the order they are listed with an empty field: what can be done to
/// the selection first (absent when nothing is selected), then the always-there rows.
enum CommandGroup: Int, CaseIterable {
    case board, project, arrange, size, navigate, create, edit

    var title: String {
        switch self {
        case .board: return String(localized: "这块白板")
        case .project: return String(localized: "项目")
        case .arrange: return String(localized: "排列")
        case .size: return String(localized: "大小")
        case .navigate: return String(localized: "导航")
        case .create: return String(localized: "新建")
        case .edit: return String(localized: "编辑")
        }
    }
}

/// What a command needs to be listed at all.
enum CommandNeeds: Equatable {
    case nothing
    /// At least this many selected cards (arranging one card means nothing).
    case cards(Int)
    /// Exactly one selected card, and it is a sub-board.
    case oneBoard
    /// A step the runner can undo.
    case undoStep
    /// Projects (selected, or the board the user is on) of which some are not on this list yet.
    case project(ProjectStatus)
}

/// What ⌘C found, as far as listing commands goes.
struct SelectionContext: Equatable {
    var count = 0
    var singleBoard = false
    var canUndo = false
    /// Where the projects a status command would act on are now (`CommandRunner.projectTargets`).
    var projectStatuses: Set<ProjectStatus> = []
}

struct CommandSpec {
    let id: String
    let title: String          // shown in the list; may contain a placeholder filled from args
    let hint: String
    let symbol: String         // SF Symbol name
    let aliases: [String]      // lowercase; Chinese, English, pinyin
    let group: CommandGroup
    let needs: CommandNeeds
    let build: (ParsedArgs) -> CommandKind
    let display: (ParsedArgs) -> String
}

struct ParsedArgs: Equatable {
    var number: Int?                 // first standalone integer, e.g. "grid 4" / "排成4列"
    var order = SortOrder()          // from modifier words: 逆序 / reverse / 按标题 / by date …
}

struct CommandMatch: Identifiable {
    let spec: CommandSpec
    let args: ParsedArgs
    let score: Int
    /// Score of the last typed word alone: the tie-breaker, since the latest word is the most specific.
    let lastWordScore: Int
    var id: String { spec.id }
    var title: String { spec.display(args) }
    var kind: CommandKind { spec.build(args) }
}

enum CommandCatalog {
    static let defaultColumns = 3
    /// Three fixed card sizes (4:3, Allume's default card is 200×150 = 中). No free-form sizes.
    static let sizes: [(name: String, width: Int, height: Int)] = [
        (String(localized: "小"), 160, 120), (String(localized: "中"), 200, 150), (String(localized: "大"), 280, 210),
    ]

    /// Catalog order is the tie-break when typing. With an empty field the panel lists the
    /// available commands by `group` (CommandGroup order): with nothing selected that is
    /// ⌘K ⏎ "最近去过", ⌘K ↓ ⏎ "全部待办", ⌘K ↓↓ ⏎ "回首页", ⌘K ↓↓↓ ⏎ "今天"; with cards
    /// selected their commands come first. Hints of the navigation rows are filled in live by
    /// the panel (last board, number of todos).
    static let specs: [CommandSpec] = [
        CommandSpec(id: "recent", title: String(localized: "最近去过"), hint: String(localized: "回到之前看过的白板"),
                    symbol: "clock.arrow.circlepath",
                    aliases: ["最近", "去过", "足迹", "回去", "历史", "刚才", "recent", "back", "history", "visited", "zuijin", "zuji"],
                    group: .navigate, needs: .nothing,
                    build: { _ in .recentBoards },
                    display: { _ in String(localized: "最近去过") }),
        CommandSpec(id: "todos", title: String(localized: "全部待办"), hint: String(localized: "所有 @todo 卡"),
                    symbol: "checklist",
                    aliases: ["待办", "todo", "todos", "任务", "到期", "截止", "过期", "@todo", "tasks", "due", "daiban", "renwu"],
                    group: .navigate, needs: .nothing,
                    build: { _ in .allTodos },
                    display: { _ in String(localized: "全部待办") }),
        CommandSpec(id: "home", title: String(localized: "回首页"), hint: String(localized: "当前 workspace 的顶层白板"),
                    symbol: "house",
                    aliases: ["回首页", "首页", "主页", "顶层", "根", "home", "root", "top", "shouye", "zhuye"],
                    group: .navigate, needs: .nothing,
                    build: { _ in .home },
                    display: { _ in String(localized: "回首页") }),
        CommandSpec(id: "today", title: String(localized: "今天"), hint: String(localized: "今天的 daily note"),
                    symbol: "calendar",
                    aliases: ["今天", "今日", "日记", "每日", "daily", "today", "journal", "jintian", "jinri", "riji"],
                    group: .navigate, needs: .nothing,
                    build: { _ in .day(offset: 0) },
                    display: { _ in String(localized: "今天") }),
        CommandSpec(id: "yesterday", title: String(localized: "昨天"), hint: String(localized: "昨天的 daily note"),
                    symbol: "chevron.left.circle",
                    aliases: ["昨天", "昨日", "yesterday", "prev", "previous", "zuotian", "zuori"],
                    group: .navigate, needs: .nothing,
                    build: { _ in .day(offset: -1) },
                    display: { _ in String(localized: "昨天") }),
        CommandSpec(id: "tomorrow", title: String(localized: "明天"), hint: String(localized: "明天的 daily note"),
                    symbol: "chevron.right.circle",
                    aliases: ["明天", "明日", "tomorrow", "next", "mingtian", "mingri"],
                    group: .navigate, needs: .nothing,
                    build: { _ in .day(offset: 1) },
                    display: { _ in String(localized: "明天") }),
        CommandSpec(id: "this-month", title: String(localized: "本月"), hint: String(localized: "这个月的日历白板"),
                    symbol: "calendar.badge.clock",
                    aliases: ["本月", "这个月", "当月", "月历", "日历", "month", "thismonth", "calendar", "benyue", "dangyue", "yueli", "rili"],
                    group: .navigate, needs: .nothing,
                    build: { _ in .thisMonth },
                    display: { _ in String(localized: "本月") }),
        CommandSpec(id: "add-todo", title: String(localized: "添加待办"), hint: String(localized: "在眼前贴一张 @todo 卡"),
                    symbol: "plus.circle",
                    aliases: ["添加待办", "加待办", "新待办", "新建待办", "记待办", "添加", "新建", "便签", "贴",
                              "add", "new", "addtodo", "note", "tianjia", "jiadaiban", "xinjian"],
                    group: .create, needs: .nothing,
                    build: { _ in .addTodo },
                    display: { _ in String(localized: "添加待办") }),
        CommandSpec(id: "add-to-day", title: String(localized: "记到某天"), hint: String(localized: "贴到那天的 daily note"),
                    symbol: "calendar.badge.plus",
                    aliases: ["记到某天", "记到那天", "记到日记", "贴到日记", "加到日记", "日记待办", "安排", "排到",
                              "schedule", "plan", "addday", "jidao", "anpai", "riji"],
                    group: .create, needs: .nothing,
                    build: { _ in .addToDay },
                    display: { _ in String(localized: "记到某天") }),
        CommandSpec(id: "add-project", title: String(localized: "新建项目"), hint: String(localized: "建一块 project- 白板"),
                    symbol: "folder.badge.plus",
                    aliases: ["新建项目", "新项目", "项目", "建项目", "project", "newproject", "xiangmu", "xinxiangmu"],
                    group: .create, needs: .nothing,
                    build: { _ in .addProject },
                    display: { _ in String(localized: "新建项目") }),
        CommandSpec(id: "project-done", title: String(localized: "完成"), hint: String(localized: "移到 Done"),
                    symbol: "checkmark.seal",
                    aliases: ["完成", "做完", "搞定", "结束", "done", "finish", "complete", "wancheng", "zuowan"],
                    group: .project, needs: .project(.done),
                    build: { _ in .moveProjects(.done) },
                    display: { _ in String(localized: "完成") }),
        CommandSpec(id: "project-doing", title: String(localized: "移到 Doing"), hint: String(localized: "开始做"),
                    symbol: "play.circle",
                    aliases: ["开始", "进行", "进行中", "在做", "doing", "start", "kaishi", "jinxing"],
                    group: .project, needs: .project(.doing),
                    build: { _ in .moveProjects(.doing) },
                    display: { _ in String(localized: "移到 Doing") }),
        CommandSpec(id: "project-todo", title: String(localized: "移到 Todo"), hint: String(localized: "放回待做"),
                    symbol: "tray",
                    aliases: ["放回", "待做", "搁置", "以后", "todo", "backlog", "later", "fanghui"],
                    group: .project, needs: .project(.todo),
                    build: { _ in .moveProjects(.todo) },
                    display: { _ in String(localized: "移到 Todo") }),
        CommandSpec(id: "open-board", title: String(localized: "打开白板"), hint: String(localized: "进入这块白板"),
                    symbol: "arrow.right.square",
                    aliases: ["打开", "进入", "进去", "跳转", "open", "enter", "go", "dakai", "jinru"],
                    group: .board, needs: .oneBoard,
                    build: { _ in .openSelectedBoard },
                    display: { _ in String(localized: "打开白板") }),
        CommandSpec(id: "grid", title: String(localized: "排成 N 列"), hint: String(localized: "网格，可加列数：grid 4"),
                    symbol: "square.grid.3x3",
                    aliases: ["排成", "排列", "整理", "网格", "列", "grid", "arrange", "columns", "sort", "tidy", "pailie", "wangge", "zhengli"],
                    group: .arrange, needs: .cards(2),
                    build: { .gather(layout: "grid", columns: $0.number ?? defaultColumns, order: $0.order) },
                    display: { String(localized: "排成 \($0.number ?? defaultColumns) 列") + orderSuffix($0) }),
        CommandSpec(id: "row", title: String(localized: "排成一行"), hint: String(localized: "横向"),
                    symbol: "rectangle.split.3x1",
                    aliases: ["一行", "横排", "横向", "行", "row", "horizontal", "yihang", "hengpai"],
                    group: .arrange, needs: .cards(2),
                    build: { .gather(layout: "row", columns: 0, order: $0.order) },
                    display: { String(localized: "排成一行") + orderSuffix($0) }),
        CommandSpec(id: "column", title: String(localized: "排成一列"), hint: String(localized: "纵向"),
                    symbol: "rectangle.split.1x2",
                    aliases: ["一列", "竖排", "纵向", "column", "vertical", "stack", "yilie", "shupai"],
                    group: .arrange, needs: .cards(2),
                    build: { .gather(layout: "column", columns: 0, order: $0.order) },
                    display: { String(localized: "排成一列") + orderSuffix($0) }),
        CommandSpec(id: "size-medium", title: String(localized: "统一大小：中"), hint: String(localized: "200×150，Allume 默认"),
                    symbol: "square.resize",
                    aliases: ["统一", "大小", "尺寸", "中", "中等", "一样大", "同样大", "size", "same", "medium", "normal", "tongyi", "daxiao", "zhong"],
                    group: .size, needs: .cards(1),
                    build: { _ in .resize(width: sizes[1].width, height: sizes[1].height) },
                    display: { _ in String(localized: "统一大小：中") }),
        CommandSpec(id: "size-small", title: String(localized: "统一大小：小"), hint: String(localized: "160×120"),
                    symbol: "arrow.down.right.and.arrow.up.left",
                    aliases: ["小", "缩小", "减小", "变小", "small", "smaller", "shrink", "xiao", "suoxiao"],
                    group: .size, needs: .cards(1),
                    build: { _ in .resize(width: sizes[0].width, height: sizes[0].height) },
                    display: { _ in String(localized: "统一大小：小") }),
        CommandSpec(id: "size-large", title: String(localized: "统一大小：大"), hint: String(localized: "280×210"),
                    symbol: "arrow.up.left.and.arrow.down.right",
                    aliases: ["大", "放大", "变大", "增大", "large", "big", "bigger", "enlarge", "da", "fangda"],
                    group: .size, needs: .cards(1),
                    build: { _ in .resize(width: sizes[2].width, height: sizes[2].height) },
                    display: { _ in String(localized: "统一大小：大") }),
        CommandSpec(id: "undo", title: String(localized: "撤销"), hint: String(localized: "撤销上一步"),
                    symbol: "arrow.uturn.backward",
                    aliases: ["撤销", "撤回", "回退", "还原", "undo", "revert", "back", "chexiao", "huitui"],
                    group: .edit, needs: .undoStep,
                    build: { _ in .undo },
                    display: { _ in String(localized: "撤销") }),
    ]

    static func isAvailable(_ spec: CommandSpec, in context: SelectionContext) -> Bool {
        switch spec.needs {
        case .nothing: return true
        case .cards(let n): return context.count >= n
        case .oneBoard: return context.count == 1 && context.singleBoard
        case .undoStep: return context.canUndo
        case .project(let target): return !context.projectStatuses.subtracting([target]).isEmpty
        }
    }

    /// How well `text` (a board title, a todo) matches what is typed: 4 = equal, 3 = prefix,
    /// 2 = contains, 1 = every space-separated word is in it, 0 = no match. Same scale as the
    /// per-word command scores, so sections can be ranked against each other.
    static func textScore(_ query: String, _ text: String) -> Int {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let t = text.lowercased()
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        if t == q { return 4 }
        if t.hasPrefix(q) { return 3 }
        if t.contains(q) { return 2 }
        let words = q.split(separator: " ")
        return words.count > 1 && words.allSatisfy { t.contains($0) } ? 1 : 0
    }

    static func orderSuffix(_ args: ParsedArgs) -> String {
        args.order.label.map { String(localized: "（\($0)）") } ?? ""
    }

    /// Modifier words that set the sort order instead of picking a command. "按标题" and
    /// "by title" style phrases are matched after dropping 按/by.
    static let orderWords: [(words: [String], apply: (inout SortOrder) -> Void)] = [
        (["逆序", "倒序", "反序", "反过来", "倒过来", "reverse", "reversed", "desc", "descending", "nixu", "daoxu"], { $0.reversed = true }),
        (["顺序", "正序", "asc", "ascending", "shunxu", "zhengxu"], { $0.reversed = false }),
        (["标题", "名字", "名称", "字母", "title", "name", "alpha", "biaoti", "mingzi"], { $0.key = .title }),
        (["时间", "日期", "创建", "新旧", "date", "time", "created", "newest", "oldest", "shijian", "riqi"], { $0.key = .created }),
    ]

    /// Commands matching `query`, best first. Empty query lists everything in catalog order.
    static func matches(for query: String) -> [CommandMatch] {
        var args = parseArgs(query)
        var words: [String] = []
        for w in normalizedWords(query) {
            if w == "by" { continue }
            // A CJK run can hold several words ("按时间逆序", "列倒序"): peel modifier words off it.
            var rest = w
            var changed = true
            while changed {
                changed = false
                for rule in orderWords {
                    for m in rule.words where rest.contains(m) {
                        rule.apply(&args.order)
                        rest = rest.replacingOccurrences(of: m, with: "")
                        changed = true
                    }
                }
            }
            rest = rest.replacingOccurrences(of: "按", with: "")
            if !rest.isEmpty { words.append(rest) }
        }
        if words.isEmpty {
            // Only modifiers (e.g. "逆序"): they apply to the default layout, grid.
            let list = args.order == SortOrder() ? specs : specs.filter { $0.id == "grid" || $0.id == "row" || $0.id == "column" }
            return list.map { CommandMatch(spec: $0, args: args, score: 0, lastWordScore: 0) }
        }
        return specs.compactMap { spec in
            // Every word must match some alias, or a word of the title as the UI shows it (so
            // "all todos" finds All Todos in English, where "all" is no alias); the score is the
            // sum of the best per-word scores.
            let pool = spec.aliases + titleWords(spec)
            var total = 0, last = 0
            for w in words {
                let best = pool.map { score(word: w, alias: $0) }.max() ?? 0
                if best == 0 { return nil }
                total += best
                last = best
            }
            return CommandMatch(spec: spec, args: args, score: total, lastWordScore: last)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.lastWordScore != $1.lastWordScore { return $0.lastWordScore > $1.lastWordScore }
            return order($0.spec) < order($1.spec)
        }
    }

    private static func order(_ spec: CommandSpec) -> Int { specs.firstIndex { $0.id == spec.id } ?? 0 }

    /// Lowercased words with digits removed (those become args).
    /// The words of a command's localized title ("Same Size: Medium" → same, size, medium), minus
    /// connecting words that would match everything; Chinese titles stay one run, like the aliases.
    private static func titleWords(_ spec: CommandSpec) -> [String] {
        let skip: Set<String> = ["a", "an", "the", "in", "to", "of", "n"]
        return normalizedWords(spec.title.replacingOccurrences(of: ":", with: " ")).filter { !skip.contains($0) }
    }

    static func normalizedWords(_ query: String) -> [String] {
        var q = query.lowercased()
        q = q.replacingOccurrences(of: #"\d+"#, with: " ", options: .regularExpression)
        // Chinese has no spaces: split CJK runs from Latin runs, keep CJK runs whole.
        var words: [String] = []
        var current = ""
        var currentIsCJK: Bool?
        func flush() { if !current.isEmpty { words.append(current) }; current = ""; currentIsCJK = nil }
        for ch in q {
            if ch.isWhitespace || ch.isPunctuation { flush(); continue }
            let cjk = ch.unicodeScalars.first.map { (0x3400...0x9FFF).contains(Int($0.value)) } ?? false
            if let c = currentIsCJK, c != cjk { flush() }
            currentIsCJK = cjk
            current.append(ch)
        }
        flush()
        return words
    }

    /// 4 = exact, 3 = prefix (or a multi-character alias inside the word, e.g. 统一大小 ⊃ 统一),
    /// 2 = substring either way, 1 = subsequence, 0 = none.
    static func score(word: String, alias: String) -> Int {
        if word == alias { return 4 }
        if alias.hasPrefix(word) { return 3 }
        if word.contains(alias), alias.count >= 2 { return 3 }
        if alias.contains(word) || word.contains(alias) { return 2 }
        return isSubsequence(word, of: alias) ? 1 : 0
    }

    private static func isSubsequence(_ small: String, of big: String) -> Bool {
        guard small.count >= 2 else { return false }
        var it = big.makeIterator()
        for ch in small {
            var found = false
            while let b = it.next() { if b == ch { found = true; break } }
            if !found { return false }
        }
        return true
    }

    static func parseArgs(_ query: String) -> ParsedArgs {
        var args = ParsedArgs()
        let ns = query as NSString
        let nums = (try? NSRegularExpression(pattern: #"\d+"#))?
            .matches(in: query, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range)) } ?? []
        args.number = nums.first
        if let n = args.number, n <= 0 || n > 50 { args.number = nil }
        return args
    }
}
