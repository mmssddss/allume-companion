import CoreGraphics

/// Where the panel goes over an Allume window, in AppKit screen coordinates. Pure geometry
/// (CoreGraphics only), so it can be checked with a swiftc script: full screen, Split View, a
/// narrow or short window, a window half off the screen.
///
/// - Centred on the part of the window that is on its screen (a window dragged half off the
///   edge centres the panel on what can be seen), never higher than `topInset` below its top
///   edge (Allume's title bar and toolbar; in full screen the window is the whole screen and the
///   toolbar is still there).
/// - `width` wide, or narrower in a narrow window (Split View on a small screen), down to
///   `minWidth`; kept `screenMargin` inside the screen's left and right edges.
/// - Up to `maxHeight` tall; shorter only when the window is.
enum PanelPlacement {
    static let topInset: CGFloat = 52
    static let minWidth: CGFloat = 420
    /// Space kept between the panel and the window's sides when the window is narrow.
    static let sideMargin: CGFloat = 12
    static let screenMargin: CGFloat = 8

    static func frame(window w: CGRect, screen: CGRect?, width: CGFloat, maxHeight: CGFloat) -> CGRect {
        var area = w
        if let screen {
            let visible = w.intersection(screen)
            if !visible.isNull, visible.width > 0, visible.height > 0 { area = visible }
        }
        let panelWidth = min(width, max(minWidth, area.width - 2 * sideMargin))
        let top = min(area.maxY - topInset, area.midY + maxHeight / 2)
        let height = min(maxHeight, max(120, top - area.minY - 16))
        var x = area.midX - panelWidth / 2
        if let screen { x = min(max(x, screen.minX + screenMargin), screen.maxX - screenMargin - panelWidth) }
        return CGRect(x: x.rounded(), y: (top - height).rounded(), width: panelWidth, height: height)
    }

    /// The screen a window is mostly on (by overlapping area); nil when it is on none.
    static func screen(for w: CGRect, among screens: [CGRect]) -> CGRect? {
        var best: CGRect?
        var bestArea: CGFloat = 0
        for s in screens {
            let overlap = s.intersection(w)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea { best = s; bestArea = area }
        }
        return best
    }
}
