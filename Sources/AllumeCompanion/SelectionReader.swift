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
/// (≤ `timeout`) → parse → restore the snapshot (marked transient, see `restoreMarkers`). Measured: Allume writes 30–110 ms after the
/// ⌘C, so `timeout` is about twice that; with nothing selected it is how long the panel's list
/// waits to unfold. If Allume is slower (a huge board, a busy machine), the wait gives up but
/// keeps watching for `lateWatch` more: a late write is then still parsed, the user's clipboard
/// still restored, and the cards delivered through `onLateSelection`.
enum SelectionReader {
    static let cardType = NSPasteboard.PasteboardType("com.allume.copyable.card")
    static let timeout: TimeInterval = 0.2
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
        case notFrontmost
        case timeout
        /// Allume wrote its own types but none parsed as a card: most likely Allume changed the
        /// private format (an update), not something the user did.
        case unrecognized

        var errorDescription: String? {
            switch self {
            case .notTrusted: return String(localized: "没有辅助功能权限，无法向 Allume 发送 ⌘C")
            case .noAllume: return String(localized: "Allume 没在运行")
            case .notFrontmost: return String(localized: "Allume 不在前台，没有读选中")
            case .timeout: return String(localized: "Allume 在 \(Int(SelectionReader.timeout * 1000))ms 内没有写剪贴板：可能没有选中卡片，或焦点不在画布上")
            case .unrecognized: return String(localized: "认不出 Allume 复制的卡片，可能是 Allume 更新了。菜单栏 → 复制诊断信息，发到 GitHub issue")
            }
        }
    }

    @MainActor
    static func capture(pid: pid_t?) async throws -> [Card] {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
        guard let pid else { throw Failure.noAllume }
        guard await waitUntilFrontmost(pid) else { throw Failure.notFrontmost }
        let pb = NSPasteboard.general
        let t0 = Date()
        let saved = snapshot(pb)
        let bytes = saved.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
        let snapMs = Int(Date().timeIntervalSince(t0) * 1000)
        if snapMs > 20 || bytes > 1_000_000 { Log.info("pasteboard snapshot: \(saved.count) items, \(bytes) bytes, \(snapMs) ms") }
        let before = pb.changeCount

        guard postCommand(key: 8, to: pid) else { throw Failure.notFrontmost } // kVK_ANSI_C

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

        let written = Date()
        let cards = parse(pb)
        let types = (pb.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
        let after = pb.changeCount
        restore(pb, saved)
        // How long Allume's card data sat in the clipboard (as far as we can see it): the window in
        // which a clipboard manager could record it. Logged after the restore, not before.
        let heldMs = Int(Date().timeIntervalSince(written) * 1000)
        Log.info("pasteboard after ⌘C: changeCount \(before)→\(after), items=\(types); restored \(heldMs) ms after Allume wrote")
        if cards.isEmpty, types.joined().contains(where: { $0.hasPrefix("com.allume.copyable") }) { throw Failure.unrecognized }
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
    ///
    /// Only while Allume is the active app. Measured: posted to Allume in the background, the down
    /// registers but the up does not, and Allume (Catalyst) key-repeats the command — ⌘C rewrote
    /// the clipboard ~29 times a second, so whatever the user copied was gone within 35 ms, until
    /// Allume was activated and left again. A second key-up posted to it did not stop it.
    @discardableResult
    static func postCommand(key: CGKeyCode, to pid: pid_t) -> Bool {
        guard NSRunningApplication(processIdentifier: pid)?.isActive == true else {
            Log.info("not posting ⌘ key \(key): Allume is not the active app")
            return false
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    /// Waits (up to `timeout`) for `pid` to become the active app, e.g. right after `activate()`.
    @MainActor
    static func waitUntilFrontmost(_ pid: pid_t, timeout: TimeInterval = 1) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while NSRunningApplication(processIdentifier: pid)?.isActive != true {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
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

    /// nspasteboard.org markers on the restored items: "on the pasteboard only briefly / not copied
    /// by the user", so clipboard managers don't record the restore as a fresh copy. Measured with
    /// Paste: without them every ⌘K bumped the user's last clip to "just now"; with them it is
    /// left alone. Allume's own write lasts a few ms and Paste never recorded it (it waits for the
    /// pasteboard to settle; even 300 ms flickers were skipped).
    static let restoreMarkers = ["org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        .map { NSPasteboard.PasteboardType($0) }

    static func restore(_ pb: NSPasteboard, _ snapshot: Snapshot) {
        pb.clearContents()
        let items: [NSPasteboardItem] = snapshot.compactMap { dict in
            guard !dict.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            for m in restoreMarkers where dict[m] == nil { item.setData(Data(), forType: m) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
