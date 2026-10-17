import AppKit
import Foundation

/// Reads the cards currently selected in Allume.
///
/// Allume exposes no selection API and its cards are not in the Accessibility tree, so the only
/// bypass is the clipboard: on ⌘C Allume writes one pasteboard item per selected card with the
/// private type `com.allume.copyable.card`, whose JSON holds base64 `scopeId` (parent board
/// prefix) and `cardId` (suffix). `hex(scopeId):hex(cardId)` is exactly the qualified id the CLI uses.
///
/// Flow: snapshot the pasteboard → post ⌘C to Allume's pid → wait for changeCount to move
/// (≤ `timeout`) → parse → restore the snapshot. Measured: Allume writes 30–110 ms after the
/// ⌘C. If it is slower than `timeout` (a huge board, a busy machine), the wait gives up but
/// keeps watching for `lateWatch` more: a late write is then still parsed, the user's clipboard
/// still restored, and the cards delivered through `onLateSelection`.
enum SelectionReader {
    static let cardType = NSPasteboard.PasteboardType("com.allume.copyable.card")
    static let timeout: TimeInterval = 0.4
    static let lateWatch: TimeInterval = 1.5
    /// Cards that arrived after `capture` had already thrown `.timeout` (main actor).
    @MainActor static var onLateSelection: (([Card]) -> Void)?

    struct Card: Equatable {
        let id: String
        let position: CGPoint?
        let docType: String?
    }

    enum Failure: Error, LocalizedError {
        case notTrusted
        case noAllume
        case timeout

        var errorDescription: String? {
            switch self {
            case .notTrusted: return "没有辅助功能权限，无法向 Allume 发送 ⌘C"
            case .noAllume: return "Allume 没在运行"
            case .timeout: return "Allume 在 \(Int(SelectionReader.timeout * 1000))ms 内没有写剪贴板：可能没有选中卡片，或焦点不在画布上"
            }
        }
    }

    @MainActor
    static func capture(pid: pid_t?) async throws -> [Card] {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
        guard let pid else { throw Failure.noAllume }
        let pb = NSPasteboard.general
        let t0 = Date()
        let saved = snapshot(pb)
        let bytes = saved.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
        let snapMs = Int(Date().timeIntervalSince(t0) * 1000)
        if snapMs > 20 || bytes > 1_000_000 { Log.info("pasteboard snapshot: \(saved.count) items, \(bytes) bytes, \(snapMs) ms") }
        let before = pb.changeCount

        postCommand(key: 8, to: pid) // kVK_ANSI_C

        let deadline = Date().addingTimeInterval(timeout)
        while pb.changeCount == before {
            if Date() > deadline {
                watchLate(pb, before: before, saved: saved)
                throw Failure.timeout
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        // Allume writes all items in one pasteboard transaction (one changeCount step), so no
        // settle delay is needed; measured: changeCount moves ~40–70 ms after the ⌘C is posted.

        let cards = parse(pb)
        Log.info("pasteboard after ⌘C: changeCount \(before)→\(pb.changeCount), items=\((pb.pasteboardItems ?? []).map { $0.types.map(\.rawValue) })")
        restore(pb, saved)
        return cards
    }

    /// After a timeout: if Allume writes within `lateWatch`, restore the clipboard and hand the
    /// cards on. Without this a late write would leave Allume's card data in the user's clipboard.
    @MainActor
    private static func watchLate(_ pb: NSPasteboard, before: Int, saved: Snapshot) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(lateWatch)
            while pb.changeCount == before {
                if Date() > deadline { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            let items = pb.pasteboardItems ?? []
            guard items.contains(where: { $0.types.contains(cardType) }) else {
                Log.info("pasteboard changed after the ⌘C timeout, but not by Allume; left alone")
                return
            }
            let cards = parse(pb)
            restore(pb, saved)
            Log.info("late ⌘C: \(cards.count) cards \(Int(Date().timeIntervalSince(deadline.addingTimeInterval(-lateWatch - timeout)) * 1000)) ms after the ⌘C; clipboard restored")
            onLateSelection?(cards)
        }
    }

    // MARK: - ⌘C

    /// Posts ⌘<key> (a down and an up) straight to `pid`. Used for ⌘C here and, after a jump,
    /// for ⌘[ (see `CommandRunner.openBoard`); those are the only keys sent to Allume.
    static func postCommand(key: CGKeyCode, to pid: pid_t) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }

    // MARK: - Parse

    static func parse(_ pb: NSPasteboard) -> [Card] {
        var cards: [Card] = []
        for item in pb.pasteboardItems ?? [] {
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                let isCardType = type == cardType
                // Also accept a dyn.* UTI carrying the same payload shape, but not the
                // `com.allume.copyable.selection` item (which has cardInfos instead of cardId).
                if !isCardType {
                    guard let s = String(data: data, encoding: .utf8),
                          s.contains("\"cardId\""), s.contains("\"scopeId\""), !s.contains("cardInfos") else { continue }
                }
                if let card = decodeCard(data) {
                    cards.append(card)
                    break
                }
            }
        }
        return cards
    }

    private static func decodeCard(_ data: Data) -> Card? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scope = (obj["scopeId"] as? [String: Any])?["data"] as? String,
              let card = (obj["cardId"] as? [String: Any])?["data"] as? String,
              let scopeData = Data(base64Encoded: scope),
              let cardData = Data(base64Encoded: card) else { return nil }
        let hex = { (d: Data) in d.map { String(format: "%02x", $0) }.joined() }
        var position: CGPoint?
        if let p = obj["cardPosition"] as? [Double], p.count == 2 { position = CGPoint(x: p[0], y: p[1]) }
        return Card(id: hex(scopeData) + ":" + hex(cardData), position: position, docType: obj["docType"] as? String)
    }

    // MARK: - Snapshot / restore

    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { dict[t] = d } }
            return dict
        }
    }

    static func restore(_ pb: NSPasteboard, _ snapshot: Snapshot) {
        pb.clearContents()
        let items: [NSPasteboardItem] = snapshot.compactMap { dict in
            guard !dict.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
