import AppKit
import ApplicationServices

/// Where on the board the user is looking. Allume's AX tree has each card's title as an
/// `AXTextField` in screen coordinates, for the whole board and not only what is on screen, and
/// screen = board × zoom + offset. Pairing the titles that occur once on the board with the
/// model's frames gives zoom and offset by least squares (the title's small inset above the card
/// ends up in the offset); the middle of the window then maps back to board coordinates.
/// Needs at least two such titles at different places.
enum BoardViewport {
    struct Fit {
        let zoom: Double
        /// Board coordinates under the middle of Allume's canvas.
        let center: CGPoint
        let pairs: Int
    }

    /// Height of Allume's toolbar strip above the canvas, so the centre is the canvas's.
    static let toolbar: CGFloat = 48

    static func fit(pid: pid_t, rows: [BoardCard]) -> Fit? {
        let app = AXUIElementCreateApplication(pid)
        guard let w = AXDump.attr(app, kAXFocusedWindowAttribute) ?? AXDump.attr(app, kAXMainWindowAttribute) else { return nil }
        let window = w as! AXUIElement
        guard let pos = point(window, kAXPositionAttribute), let size = size(window, kAXSizeAttribute) else { return nil }

        var screen: [String: [CGPoint]] = [:]
        var visited = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth <= 30, visited < 5000 else { return }
            visited += 1
            if AXDump.attr(el, kAXRoleAttribute) as? String == kAXTextFieldRole,
               let v = AXDump.attr(el, kAXValueAttribute) as? String, !v.isEmpty, let p = point(el, kAXPositionAttribute) {
                screen[v, default: []].append(p)
            }
            for c in AXDump.attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(c, depth + 1) }
        }
        walk(window, 0)

        var titled: [String: [BoardCard.Frame]] = [:]
        for r in rows { if let t = r.title, !t.isEmpty { titled[t, default: []].append(r.frame) } }
        let pairs: [(f: CGPoint, s: CGPoint)] = titled.compactMap { t, frames in
            guard frames.count == 1, let s = screen[t], s.count == 1 else { return nil }
            return (CGPoint(x: frames[0].x, y: frames[0].y), s[0])
        }
        guard pairs.count >= 2 else { return nil }
        let n = Double(pairs.count)
        let mfx = pairs.map { Double($0.f.x) }.reduce(0, +) / n, mfy = pairs.map { Double($0.f.y) }.reduce(0, +) / n
        let msx = pairs.map { Double($0.s.x) }.reduce(0, +) / n, msy = pairs.map { Double($0.s.y) }.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for p in pairs {
            let dx = Double(p.f.x) - mfx, dy = Double(p.f.y) - mfy
            num += dx * (Double(p.s.x) - msx) + dy * (Double(p.s.y) - msy)
            den += dx * dx + dy * dy
        }
        guard den > 1 else { return nil }
        let zoom = num / den
        guard (0.05...20).contains(zoom) else { return nil }
        let bx = msx - zoom * mfx, by = msy - zoom * mfy
        let cx = Double(pos.x + size.width / 2), cy = Double(pos.y + toolbar + (size.height - toolbar) / 2)
        return Fit(zoom: zoom, center: CGPoint(x: (cx - bx) / zoom, y: (cy - by) / zoom), pairs: pairs.count)
    }

    /// Top-left for a new card of `size` as close to `center` as possible without touching any
    /// of `cards` (each grown by its title band above and a margin). Grid search, 40 pt steps,
    /// up to 600 pt away; `center` itself when nothing is free.
    static func freeSpot(near center: CGPoint, size: CGSize, avoiding cards: [BoardCard.Frame]) -> CGPoint {
        let titleBand: CGFloat = 30, margin: CGFloat = 20, step: CGFloat = 40
        let taken = cards.map {
            CGRect(x: $0.x, y: $0.y - titleBand, width: $0.width, height: $0.height + titleBand).insetBy(dx: -margin, dy: -margin)
        }
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        var offsets: [CGPoint] = []
        for i in -15...15 { for j in -15...15 { offsets.append(CGPoint(x: CGFloat(i) * step, y: CGFloat(j) * step)) } }
        offsets.sort { hypot($0.x, $0.y) < hypot($1.x, $1.y) }
        for o in offsets {
            let p = CGPoint(x: origin.x + o.x, y: origin.y + o.y)
            guard p.x >= 0, p.y >= titleBand else { continue }
            let r = CGRect(x: p.x, y: p.y - titleBand, width: size.width, height: size.height + titleBand)
            if !taken.contains(where: { $0.intersects(r) }) { return p }
        }
        return origin
    }

    private static func point(_ el: AXUIElement, _ name: String) -> CGPoint? {
        guard let v = AXDump.attr(el, name) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private static func size(_ el: AXUIElement, _ name: String) -> CGSize? {
        guard let v = AXDump.attr(el, name) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
}
