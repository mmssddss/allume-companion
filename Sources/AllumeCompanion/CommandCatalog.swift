import Foundation

/// The commands the Spotlight-style panel can run, with multilingual aliases and argument parsing.
/// Pure Swift (no AppKit) so it can be unit-tested with a plain `swiftc` build.
enum CommandKind: Equatable {
    case gather(layout: String, columns: Int)   // card-gather --layout grid|row|column
    case resize(width: Int, height: Int)        // card-move --width --height on each card (one of `sizes`)
    case undo
}

struct CommandSpec {
    let id: String
    let title: String          // shown in the list; may contain a placeholder filled from args
    let hint: String
    let symbol: String         // SF Symbol name
    let aliases: [String]      // lowercase; Chinese, English, pinyin
    let needsSelection: Bool
    let build: (ParsedArgs) -> CommandKind
    let display: (ParsedArgs) -> String
}

struct ParsedArgs: Equatable {
    var number: Int?                 // first standalone integer, e.g. "grid 4" / "排成4列"
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
        ("小", 160, 120), ("中", 200, 150), ("大", 280, 210),
    ]

    static let specs: [CommandSpec] = [
        CommandSpec(id: "grid", title: "排成 N 列", hint: "网格，锚在选中区域左上角，可加数字：grid 4 / 排成4列",
                    symbol: "square.grid.3x3",
                    aliases: ["排成", "排列", "整理", "网格", "列", "grid", "arrange", "columns", "sort", "tidy", "pailie", "wangge", "zhengli"],
                    needsSelection: true,
                    build: { .gather(layout: "grid", columns: $0.number ?? defaultColumns) },
                    display: { "排成 \($0.number ?? defaultColumns) 列" }),
        CommandSpec(id: "row", title: "排成一行", hint: "横向排成一行",
                    symbol: "rectangle.split.3x1",
                    aliases: ["一行", "横排", "横向", "行", "row", "horizontal", "yihang", "hengpai"],
                    needsSelection: true,
                    build: { _ in .gather(layout: "row", columns: 0) },
                    display: { _ in "排成一行" }),
        CommandSpec(id: "column", title: "排成一列", hint: "纵向排成一列",
                    symbol: "rectangle.split.1x2",
                    aliases: ["一列", "竖排", "纵向", "column", "vertical", "stack", "yilie", "shupai"],
                    needsSelection: true,
                    build: { _ in .gather(layout: "column", columns: 0) },
                    display: { _ in "排成一列" }),
        CommandSpec(id: "size-medium", title: "统一大小：中", hint: "200×150（Allume 默认大小）",
                    symbol: "square.resize",
                    aliases: ["统一", "大小", "尺寸", "中", "中等", "一样大", "同样大", "size", "same", "medium", "normal", "tongyi", "daxiao", "zhong"],
                    needsSelection: true,
                    build: { _ in .resize(width: sizes[1].width, height: sizes[1].height) },
                    display: { _ in "统一大小：中" }),
        CommandSpec(id: "size-small", title: "统一大小：小", hint: "160×120",
                    symbol: "arrow.down.right.and.arrow.up.left",
                    aliases: ["小", "缩小", "减小", "变小", "small", "smaller", "shrink", "xiao", "suoxiao"],
                    needsSelection: true,
                    build: { _ in .resize(width: sizes[0].width, height: sizes[0].height) },
                    display: { _ in "统一大小：小" }),
        CommandSpec(id: "size-large", title: "统一大小：大", hint: "280×210",
                    symbol: "arrow.up.left.and.arrow.down.right",
                    aliases: ["大", "放大", "变大", "增大", "large", "big", "bigger", "enlarge", "da", "fangda"],
                    needsSelection: true,
                    build: { _ in .resize(width: sizes[2].width, height: sizes[2].height) },
                    display: { _ in "统一大小：大" }),
        CommandSpec(id: "undo", title: "撤销", hint: "撤销上一步（Allume 自己的 ⌘Z 撤不掉 CLI 做的事）",
                    symbol: "arrow.uturn.backward",
                    aliases: ["撤销", "撤回", "回退", "还原", "undo", "revert", "back", "chexiao", "huitui"],
                    needsSelection: false,
                    build: { _ in .undo },
                    display: { _ in "撤销" }),
    ]

    /// Commands matching `query`, best first. Empty query lists everything in catalog order.
    static func matches(for query: String) -> [CommandMatch] {
        let args = parseArgs(query)
        let words = normalizedWords(query)
        if words.isEmpty {
            return specs.map { CommandMatch(spec: $0, args: args, score: 0, lastWordScore: 0) }
        }
        return specs.compactMap { spec in
            // Every word must match some alias; the score is the sum of the best per-word scores.
            var total = 0, last = 0
            for w in words {
                let best = spec.aliases.map { score(word: w, alias: $0) }.max() ?? 0
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
