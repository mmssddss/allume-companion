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
/// (≤ 300 ms) → parse → restore the snapshot.
enum SelectionReader {
    static let cardType = NSPasteboard.PasteboardType("com.allume.copyable.card")

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
            case .timeout: return "Allume 在 300ms 内没有写剪贴板：可能没有选中卡片，或焦点不在画布上"
            }
        }
    }

    @MainActor
    static func capture(pid: pid_t?) async throws -> [Card] {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
        guard let pid else { throw Failure.noAllume }
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount

        postCommandC(to: pid)

        let deadline = Date().addingTimeInterval(0.3)
        while pb.changeCount == before {
            if Date() > deadline {
                throw Failure.timeout
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // Give Allume a moment to finish writing every item of a multi-card selection.
        try? await Task.sleep(nanoseconds: 20_000_000)

        let cards = parse(pb)
        restore(pb, saved)
        return cards
    }

    // MARK: - ⌘C

    private static func postCommandC(to pid: pid_t) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 8 // kVK_ANSI_C
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyC, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyC, keyDown: false) else { return }
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
