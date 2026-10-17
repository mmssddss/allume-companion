import Foundation

/// Natural-language due dates for the "添加待办" field: `明天`, `下周二`, `周五`, `月底`, `3天后`,
/// `20号`, `下个月 2 号`, `11月3日`, `10-20`, `2026-10-20`, … turned into a day. Weeks run Monday to Sunday,
/// so on a Saturday `下周二` is three days away and `周二` (the coming one) is the same day.
/// Our own table goes first (predictable, and it can complete a half-typed phrase);
/// what it does not know goes to the system's `NSDataDetector` (English, `后天下午3点`, …),
/// which on its own misses `月底`, `3天后`, `二十号`, `下个月`, `10-20`.
/// Pure Foundation, so it can be checked with a plain `swiftc` build.
enum DateWords {
    struct Phrase: Equatable {
        let text: String
        let date: Date
    }

    nonisolated static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    nonisolated static func iso(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    nonisolated static let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    /// "周二 · 3 天后": what a date means, for the suggestion rows.
    nonisolated static func describe(_ date: Date, today: Date = Date()) -> String {
        let cal = calendar
        let start = cal.startOfDay(for: today)
        let wd = weekdayNames[(cal.component(.weekday, from: date) + 5) % 7]
        let days = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: date)).day ?? 0
        let rel: String
        switch days {
        case 0: rel = "今天"
        case 1: rel = "明天"
        case 2: rel = "后天"
        case let d where d < 0: rel = "已过 \(-d) 天"
        default: rel = "\(days) 天后"
        }
        return "\(wd) · \(rel)"
    }

    // MARK: - Vocabulary

    /// Every fixed phrase with its day, in suggestion order (周 forms before 星期 / 礼拜 forms).
    nonisolated static func vocabulary(today: Date = Date()) -> [Phrase] {
        let cal = calendar
        let start = cal.startOfDay(for: today)
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: start)! }
        var out: [Phrase] = []
        func add(_ texts: [String], _ d: Date) { for t in texts { out.append(Phrase(text: t, date: d)) } }

        add(["今天", "今日", "today"], day(0))
        add(["明天", "明日", "tomorrow"], day(1))
        add(["后天"], day(2))
        add(["大后天"], day(3))

        let wd = (cal.component(.weekday, from: start) + 5) % 7 // Monday = 0
        let digits = ["一", "二", "三", "四", "五", "六", "日"]
        for stem in ["周", "星期", "礼拜"] {
            for i in 0..<7 {
                let names = i == 6 && stem != "周" ? ["\(stem)日", "\(stem)天"] : ["\(stem)\(digits[i])"]
                let thisWeek = day(i - wd)
                add(names, i >= wd ? thisWeek : day(i - wd + 7))   // the coming one
                add(names.map { "本" + $0 } + names.map { "这" + $0 }, thisWeek)
                add(names.map { "下" + $0 }, day(i - wd + 7))
                add(names.map { "下下" + $0 }, day(i - wd + 14))
                add(names.map { "上" + $0 }, day(i - wd - 7))
            }
            add(["下\(stem)"], day(7 - wd))
            add(["下下\(stem)"], day(14 - wd))
        }

        let comps = cal.dateComponents([.year, .month], from: start)
        let monthStart = cal.date(from: comps)!
        let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart)!
        add(["月底", "月末", "本月底"], cal.date(byAdding: .day, value: -1, to: nextMonth)!)
        add(["下个月", "下月初", "下个月初"], nextMonth)
        add(["下下个月"], cal.date(byAdding: .month, value: 1, to: nextMonth)!)
        add(["下月底", "下月末", "下个月底", "下个月末"], cal.date(byAdding: .day, value: -1, to: cal.date(byAdding: .month, value: 1, to: nextMonth)!)!)
        add(["年底", "年末"], cal.date(from: DateComponents(year: comps.year, month: 12, day: 31))!)
        return out
    }

    // MARK: - Exact phrases

    /// The day `text` names exactly, or nil. Spaces inside a Chinese phrase do not matter
    /// (`下个月 2 号` = `下个月2号`).
    nonisolated static func date(for text: String, today: Date = Date()) -> Date? {
        let t = compact(text)
        if let p = vocabulary(today: today).first(where: { $0.text == t }) { return p.date }
        return pattern(t, today: today)
    }

    nonisolated private static func compact(_ text: String) -> String {
        let t = text.lowercased()
        return t.allSatisfy(\.isASCII) ? t : t.filter { !$0.isWhitespace }
    }

    nonisolated private static let num = #"(\d{1,3}|[一二两三四五六七八九十]{1,3})"#
    nonisolated private static let patterns: [(NSRegularExpression, String)] = [
        (#"^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$"#, "ymd"),
        (#"^(\d{1,2})[-/](\d{1,2})$"#, "md"),
        ("^\(num)月\(num)[号日]$", "md"),
        ("^(下下个?月|下个?月|本月|这个?月)\(num)[号日]$", "month-d"),
        ("^\(num)[号日]$", "d"),
        ("^\(num)个?(天|周|星期|礼拜|个月)(?:之?后|以后)$", "offset"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// Whether a pattern match is finished as typed (ends in 后 / 号 / 日), so the field may
    /// replace it at once; `10-2` may still be on its way to `10-20`.
    nonisolated private static func isFinal(_ text: String, today: Date) -> Bool {
        let t = compact(text)
        guard let last = t.last else { return false }
        return "后号日".contains(last) && pattern(t, today: today) != nil
    }

    nonisolated private static func pattern(_ t: String, today: Date) -> Date? {
        let cal = calendar
        let start = cal.startOfDay(for: today)
        let ns = t as NSString
        for (re, kind) in patterns {
            guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { continue }
            func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
            switch kind {
            case "ymd":
                guard let y = Int(g(1)), let mo = Int(g(2)), let d = Int(g(3)) else { return nil }
                return valid(y, mo, d)
            case "md":
                guard let mo = number(g(1)), let d = number(g(2)) else { return nil }
                let y = cal.component(.year, from: start)
                guard let this = valid(y, mo, d) else { return nil }
                return this < start ? valid(y + 1, mo, d) : this
            case "month-d":
                guard let d = number(g(2)) else { return nil }
                let ahead = g(1).hasPrefix("下下") ? 2 : (g(1).hasPrefix("下") ? 1 : 0)
                let month = cal.date(byAdding: .month, value: ahead, to: cal.date(from: cal.dateComponents([.year, .month], from: start))!)!
                // 下个月 31 号 in a 30-day month means its last day, not some other month's 31st.
                let last = cal.range(of: .day, in: .month, for: month)!.count
                guard (1...31).contains(d) else { return nil }
                return cal.date(byAdding: .day, value: min(d, last) - 1, to: month)
            case "d":
                guard let d = number(g(1)) else { return nil }
                let c = cal.dateComponents([.year, .month], from: start)
                if let this = valid(c.year!, c.month!, d), this >= start { return this }
                let next = cal.date(byAdding: .month, value: 1, to: cal.date(from: c)!)!
                let n = cal.dateComponents([.year, .month], from: next)
                return valid(n.year!, n.month!, d)
            case "offset":
                guard let n = number(g(1)) else { return nil }
                switch g(2) {
                case "天": return cal.date(byAdding: .day, value: n, to: start)
                case "个月": return cal.date(byAdding: .month, value: n, to: start)
                default: return cal.date(byAdding: .day, value: 7 * n, to: start)
                }
            default: return nil
            }
        }
        return nil
    }

    /// Arabic or small Chinese numbers (一 … 九十九, 两).
    nonisolated static func number(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        let d: [Character: Int] = ["一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let chars = Array(s)
        if let i = chars.firstIndex(of: "十") {
            let tens = i == 0 ? 1 : d[chars[0]]
            let ones = i + 1 < chars.count ? d[chars[i + 1]] : 0
            guard let tens, let ones, i <= 1, chars.count <= i + 2 else { return nil }
            return tens * 10 + ones
        }
        return chars.count == 1 ? d[chars[0]] : nil
    }

    nonisolated private static func valid(_ y: Int, _ m: Int, _ d: Int) -> Date? {
        let cal = calendar
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)),
              cal.component(.month, from: date) == m, cal.component(.day, from: date) == d else { return nil }
        return date
    }

    // MARK: - Inside a line of text

    /// A date phrase at one end of `text`: the range it occupies and its day. The longest match
    /// wins (`大后天` over `后天`); a phrase starting or ending in a digit must not touch another
    /// digit, so `13-20` is not read as `3-20`.
    nonisolated static func match(in text: String, atEnd: Bool, today: Date = Date()) -> (range: Range<String.Index>, date: Date)? {
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }
        if let own = ownMatch(chars, text, atEnd: atEnd, today: today) { return own }
        // The system's detector, for whatever the table does not cover; its match must touch
        // the same end of the text. It reads relative words against the real clock.
        guard let detector else { return nil }
        let ns = text as NSString
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let date = m.date, let r = Range(m.range, in: text) else { continue }
            let rest = atEnd ? text[r.upperBound...] : text[..<r.lowerBound]
            if rest.allSatisfy(\.isWhitespace) { return (r, calendar.startOfDay(for: date)) }
        }
        return nil
    }

    nonisolated private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    nonisolated private static func ownMatch(_ chars: [Character], _ text: String, atEnd: Bool, today: Date) -> (range: Range<String.Index>, date: Date)? {
        for k in stride(from: min(12, chars.count), through: 1, by: -1) {
            let from = atEnd ? chars.count - k : 0
            let piece = String(chars[from..<from + k])
            guard piece.first?.isWhitespace == false, piece.last?.isWhitespace == false,
                  let date = date(for: piece, today: today) else { continue }
            let numeric: (Character) -> Bool = { $0.isNumber || "-/.".contains($0) }
            if atEnd, from > 0, numeric(chars[from - 1]), piece.first!.isNumber { continue }
            if !atEnd, k < chars.count, numeric(chars[k]), piece.last!.isNumber { continue }
            let lower = text.index(text.startIndex, offsetBy: from)
            return (lower..<text.index(lower, offsetBy: k), date)
        }
        return nil
    }

    /// What the field's tail could become: the unfinished phrase at the end of `text` (e.g. `下周`)
    /// and the fixed phrases it begins, one per day, earliest first. Empty when the tail is not
    /// the start of any phrase.
    nonisolated static func completions(for text: String, today: Date = Date(), limit: Int = 7) -> (fragment: Range<String.Index>, phrases: [Phrase])? {
        let chars = Array(text)
        let vocab = vocabulary(today: today)
        for k in stride(from: min(6, chars.count), through: 1, by: -1) {
            let piece = String(chars[(chars.count - k)...]).lowercased()
            guard piece.first?.isWhitespace == false else { continue }
            var seen = Set<Date>()
            let hits = vocab.filter { $0.text.hasPrefix(piece) && $0.text != piece && seen.insert($0.date).inserted }
            guard !hits.isEmpty else { continue }
            let lower = text.index(text.endIndex, offsetBy: -k)
            return (lower..<text.endIndex, Array(hits.sorted { $0.date < $1.date }.prefix(limit)))
        }
        return nil
    }

    /// `text` with a just-finished phrase at its end swapped for its ISO date (`交房租 下周二` →
    /// `交房租 2026-10-20`), or nil. Only phrases nothing longer could continue: `下周二` is
    /// replaced, `下周` waits (it may become `下周三`), so does anything ending in 月 (`下个月` →
    /// `下个月 2 号`), and typed dates are left alone.
    nonisolated static func autoReplace(_ text: String, today: Date = Date()) -> String? {
        guard let m = ownMatch(Array(text), text, atEnd: true, today: today) else { return nil }
        let piece = compact(String(text[m.range]))
        let vocab = vocabulary(today: today)
        let final: Bool
        if vocab.contains(where: { $0.text == piece }) {
            final = !vocab.contains { $0.text.count > piece.count && $0.text.hasPrefix(piece) }
                && !piece.hasSuffix("月")          // 下个月 may still become 下个月 2 号
                && !piece.allSatisfy(\.isASCII) // "today" could be part of an English sentence
        } else {
            final = isFinal(piece, today: today)
        }
        guard final else { return nil }
        return text.replacingCharacters(in: m.range, with: iso(m.date))
    }
}
