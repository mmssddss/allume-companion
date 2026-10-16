import AppKit
import ImageIO

/// Small previews for the card stack, fetched through the CLI after ⌘K and kept in memory by
/// card id so a card is never fetched twice while the app runs.
///
/// Where the pixels come from (see README "卡片缩略图从哪来"):
/// - image: `card-content <id> --contents raw --format json` — the original JPEG/PNG bytes on
///   stdout (metadata goes to stderr), downscaled with ImageIO to `maxEdge` px.
/// - pdf: `card-pdf-page <id> --page 1 --max-dimension 256 --format json` — a PNG on stdout.
/// - subBoard: no picture exists; `board-content <document.id> --format json` gives the frames
///   of the cards on that board and we draw a wireframe (one rounded rectangle per card).
/// - text/chain: no fetch; the panel shows the body instead (already in `board-content` rows).
/// - url/video: nothing (url has only a title; video would be the whole mp4).
@MainActor
final class ThumbnailLoader {
    /// Longest edge in pixels: the stack's 60 pt face at 2x.
    static let maxEdge = 120
    static let wireframeSize = CGSize(width: 120, height: 84)

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() { cache.countLimit = 48 }

    func cached(_ id: String) -> NSImage? { cache.object(forKey: id as NSString) }

    /// The thumbnail for `card`, from the cache or the CLI; nil for kinds without one or on
    /// failure. Concurrent requests for the same card share one fetch.
    /// `background` marks the CLI calls as prewarming (see `AllumeCLI.Counts`).
    func thumbnail(for card: CardSummary, background: Bool = false) async -> NSImage? {
        if let img = cached(card.id) { return img }
        guard Self.hasThumbnail(kind: card.kind) else { return nil }
        if let task = inFlight[card.id] { return await task.value }
        let task = Task<NSImage?, Never> { await self.fetch(card, background: background) }
        inFlight[card.id] = task
        let img = await task.value
        inFlight[card.id] = nil
        if let img { cache.setObject(img, forKey: card.id as NSString) }
        return img
    }

    static func hasThumbnail(kind: String) -> Bool {
        kind == "image" || kind == "pdf" || kind == "subBoard"
    }

    // MARK: - Fetching

    private func fetch(_ card: CardSummary, background: Bool) async -> NSImage? {
        let t0 = Date()
        var image: NSImage?
        var px = ""
        var detail = ""
        switch card.kind {
        case "image":
            let r = await AllumeCLI.run(["card-content", card.id, "--contents", "raw", "--format", "json"], raw: true, background: background)
            (image, px) = Self.downscale(r.stdoutData, maxEdge: Self.maxEdge)
            detail = "\(r.stdoutData.count) bytes"
            if image == nil { detail += " " + Self.firstLine(r.stderr) }
        case "pdf":
            let r = await AllumeCLI.run(["card-pdf-page", card.id, "--page", "1", "--max-dimension", "256", "--format", "json"], raw: true, background: background)
            (image, px) = Self.downscale(r.stdoutData, maxEdge: Self.maxEdge)
            detail = "\(r.stdoutData.count) bytes"
            if image == nil { detail += " " + Self.firstLine(r.stderr) }
        case "subBoard":
            guard let doc = card.documentId else { detail = "no document id"; break }
            let r = await AllumeCLI.run(["board-content", doc, "--format", "json"], background: background)
            if r.ok {
                let frames = Self.decodeFrames(r.stdout)
                image = Self.wireframe(frames: frames, size: Self.wireframeSize)
                px = "\(Int(Self.wireframeSize.width))×\(Int(Self.wireframeSize.height))"
                detail = "\(frames.count) cards"
            } else {
                detail = Self.firstLine(r.stderr)
            }
        default:
            return nil
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let tag = background ? "thumbnail[bg]" : "thumbnail"
        if image != nil {
            Log.info("\(tag) \(card.kind) \(card.id): \(px) px, \(detail), \(ms) ms")
        } else {
            Log.info("\(tag) \(card.kind) \(card.id): failed (\(detail)), \(ms) ms")
        }
        return image
    }

    private static func firstLine(_ s: String) -> String {
        s.split(separator: "\n").first.map(String.init) ?? ""
    }

    /// Decodes `data` (JPEG/PNG/…) straight into a thumbnail no larger than `maxEdge` px on its
    /// longer side, honouring EXIF orientation, without decoding the full-size image into memory.
    /// Also returns the pixel size as text for the log.
    static func downscale(_ data: Data, maxEdge: Int) -> (NSImage?, String) {
        guard !data.isEmpty, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return (nil, "") }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return (nil, "") }
        return (NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), "\(cg.width)×\(cg.height)")
    }

    // MARK: - Sub-board wireframe

    private struct Row: Decodable {
        struct Frame: Decodable { let x: Double, y: Double, width: Double, height: Double }
        let frame: Frame
    }

    static func decodeFrames(_ json: String) -> [CGRect] {
        ((try? JSONDecoder().decode([Row].self, from: Data(json.utf8))) ?? [])
            .map { CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height) }
    }

    /// One rounded rectangle per card, the bounding box of all cards fitted (aspect preserved,
    /// centred) into `size` pixels. Drawn with dynamic colours so it follows light/dark mode.
    static func wireframe(frames: [CGRect], size: CGSize) -> NSImage {
        let img = NSImage(size: size, flipped: true) { rect in
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
            guard let bounds = frames.dropFirst().reduce(frames.first, { $0?.union($1) }), bounds.width > 0, bounds.height > 0 else {
                return true
            }
            let inset: CGFloat = 8
            let avail = rect.insetBy(dx: inset, dy: inset)
            let scale = min(avail.width / bounds.width, avail.height / bounds.height)
            let origin = CGPoint(x: avail.midX - bounds.width * scale / 2 - bounds.minX * scale,
                                 y: avail.midY - bounds.height * scale / 2 - bounds.minY * scale)
            let fill = NSColor.textBackgroundColor
            let stroke = NSColor.secondaryLabelColor.withAlphaComponent(0.7)
            for f in frames {
                let r = CGRect(x: origin.x + f.minX * scale, y: origin.y + f.minY * scale,
                               width: max(2, f.width * scale), height: max(2, f.height * scale))
                let path = NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5)
                fill.setFill(); path.fill()
                stroke.setStroke(); path.lineWidth = 1; path.stroke()
            }
            return true
        }
        return img
    }
}
