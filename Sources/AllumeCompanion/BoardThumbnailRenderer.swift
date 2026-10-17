import AppKit
import CryptoKit
import ImageIO

/// Draws a small picture of a whole board from its `board-content --format json` rows, the way
/// Allume's own sub-board cards look: white canvas, every card shrunk into place (text cards as a
/// smear of tiny type, image cards with the real picture, PDFs with page 1, nested boards as grey
/// blocks with their title). Used by `ThumbnailLoader` for subBoard cards.
///
/// Cost: the rows are free (the caller already has them); each picture is one CLI call
/// (`card-content --contents raw` for images, `card-pdf-page --page 1` for PDFs, ~150–450 ms
/// each), so at most `maxPictures` per board are fetched (the largest on the canvas; the rest
/// are grey blocks), `concurrentFetches` at a time. Decoded pictures are kept only at
/// `pictureEdge` px.
///
/// Cache: by board document id, in memory and on disk
/// (`~/Library/Application Support/AllumeCompanion/thumbs/<id>.png` + `<id>.hash`, the id's
/// ":" written as "_"). The hash covers the fields of the rows that affect the picture (see
/// `hash`): same rows → the PNG is reused and nothing is fetched or drawn ("cache hit … 0 ms"). A render in which a picture
/// fetch failed is kept in memory only, so the next launch retries it.
///
/// Everything here runs off the main actor (`thumbnail` is nonisolated async; drawing is a
/// detached task with its own NSGraphicsContext).
final class BoardThumbnailRenderer: @unchecked Sendable {
    static let size = CGSize(width: 240, height: 180)
    /// Pictures (image + pdf cards) fetched per board; the rest are drawn as grey blocks.
    static let maxPictures = 6
    /// Longest edge kept of a decoded picture.
    static let pictureEdge = 160
    static let concurrentFetches = 2
    /// Body text kept per text card (more never shows at 2–3 pt).
    static let maxBodyLength = 400

    let directory: URL

    private let lock = NSLock()
    private var memory: [String: (hash: String, image: NSImage)] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("AllumeCompanion/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Drops the memory cache and every file under `directory` (the next look redraws).
    func clear() {
        lock.lock(); memory.removeAll(); lock.unlock()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Log.info("thumbnails: cache cleared")
    }

    // MARK: - Entry point

    /// The board's thumbnail: from memory or disk when the rows have not changed, otherwise
    /// fetched, drawn and cached. `title` is only for the log. Never nil unless the rows do not
    /// parse or drawing fails.
    func thumbnail(boardId: String, title: String, rowsJSON: String, background: Bool = false) async -> NSImage? {
        let t0 = Date()
        let tag = background ? "board thumbnail[bg]" : "board thumbnail"
        let rows = BoardCard.decodeRows(rowsJSON)
        let hash = Self.hash(rows)
        let name = "\"\(title)\" \(boardId)"

        if let hit = lock.withLock({ memory[boardId] }), hit.hash == hash {
            Log.info("\(tag) \(name): cache hit (memory), 0 ms")
            return hit.image
        }
        if let image = loadFromDisk(boardId: boardId, hash: hash) {
            lock.withLock { memory[boardId] = (hash, image) }
            Log.info("\(tag) \(name): cache hit (disk), \(rows.count) cards, \(Self.ms(since: t0)) ms")
            return image
        }

        // Pictures: the largest image/pdf cards on the canvas, up to the budget.
        let scale = Self.layout(rows).scale
        let wanted = rows
            .filter { $0.kind == "image" || $0.kind == "pdf" }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        let fetchList = Array(wanted.prefix(Self.maxPictures))
        let tFetch = Date()
        let (pictures, failed) = await fetchPictures(fetchList, background: background)
        let fetchMs = Self.ms(since: tFetch)

        let tDraw = Date()
        let drawn = await Task.detached(priority: background ? .utility : .userInitiated) {
            Self.draw(rows: rows, pictures: pictures, size: Self.size)
        }.value
        let drawMs = Self.ms(since: tDraw)
        guard let drawn else {
            Log.info("\(tag) \(name): drawing failed, \(rows.count) cards, \(Self.ms(since: t0)) ms")
            return nil
        }
        lock.withLock { memory[boardId] = (hash, drawn.image) }
        if failed == 0 { saveToDisk(boardId: boardId, hash: hash, png: drawn.png) }
        let total = Self.ms(since: t0)
        let imageCount = rows.filter { $0.kind == "image" }.count
        let pdfCount = rows.filter { $0.kind == "pdf" }.count
        var detail = "\(rows.count) cards, \(imageCount) images"
        if pdfCount > 0 { detail += ", \(pdfCount) pdfs" }
        detail += ", \(pictures.count)/\(fetchList.count) pictures fetched"
        if failed > 0 { detail += " (\(failed) failed, not cached on disk)" }
        detail += String(format: ", scale %.3f", scale)
        Log.info("\(tag) \(name): \(detail), \(Int(Self.size.width))×\(Int(Self.size.height)) px, \(total) ms (fetch \(fetchMs), draw \(drawMs))")
        return drawn.image
    }

    // MARK: - Cache

    /// SHA-256 over the parts of the rows that change the picture (id, kind, title, frame,
    /// zOrder, body, file name/size). Not over the raw JSON: `board-content` stamps every row's
    /// `createdAt` with the time of the call, so the raw text differs on every run.
    static func hash(_ rows: [BoardCard]) -> String {
        var s = ""
        for r in rows {
            let f = r.frame
            s += "\(r.id)\u{1F}\(r.kind ?? "")\u{1F}\(r.title ?? "")\u{1F}\(f.x),\(f.y),\(f.width),\(f.height)\u{1F}\(r.zOrder ?? 0)\u{1F}"
            s += "\(r.document?.id ?? "")\u{1F}\(r.document?.body ?? "")\u{1F}\(r.document?.fileName ?? "")\u{1F}\(r.document?.byteSize ?? 0)\n"
        }
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func files(for boardId: String) -> (png: URL, hash: URL) {
        let base = boardId.replacingOccurrences(of: ":", with: "_")
        return (directory.appendingPathComponent(base + ".png"), directory.appendingPathComponent(base + ".hash"))
    }

    private func loadFromDisk(boardId: String, hash: String) -> NSImage? {
        let f = files(for: boardId)
        guard let stored = try? String(contentsOf: f.hash, encoding: .utf8),
              stored.trimmingCharacters(in: .whitespacesAndNewlines) == hash,
              let data = try? Data(contentsOf: f.png),
              let image = NSImage(data: data) else { return nil }
        return image
    }

    private func saveToDisk(boardId: String, hash: String, png: Data) {
        let f = files(for: boardId)
        do {
            try png.write(to: f.png, options: .atomic)
            try Data(hash.utf8).write(to: f.hash, options: .atomic)
        } catch {
            Log.info("board thumbnail: could not write \(f.png.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Pictures

    /// Fetches and decodes the pictures of `cards` (`concurrentFetches` at a time), keyed by
    /// card id; also returns how many fetches failed.
    private func fetchPictures(_ cards: [BoardCard], background: Bool) async -> ([String: CGImage], Int) {
        var pictures: [String: CGImage] = [:]
        var failed = 0
        for start in stride(from: 0, to: cards.count, by: Self.concurrentFetches) {
            let batch = cards[start..<min(start + Self.concurrentFetches, cards.count)]
            let results = await withTaskGroup(of: (String, CGImage?).self, returning: [(String, CGImage?)].self) { group in
                for card in batch {
                    group.addTask { (card.id, await Self.fetchPicture(card, background: background)) }
                }
                var out: [(String, CGImage?)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (id, image) in results {
                if let image { pictures[id] = image } else { failed += 1 }
            }
        }
        return (pictures, failed)
    }

    private static func fetchPicture(_ card: BoardCard, background: Bool) async -> CGImage? {
        let args: [String]
        switch card.kind {
        case "image": args = ["card-content", card.id, "--contents", "raw", "--format", "json"]
        case "pdf": args = ["card-pdf-page", card.id, "--page", "1", "--max-dimension", "256", "--format", "json"]
        default: return nil
        }
        let r = await AllumeCLI.run(args, raw: true, background: background)
        guard let cg = ThumbnailLoader.decode(r.stdoutData, maxEdge: pictureEdge) else {
            Log.info("board thumbnail: \(card.kind ?? "") \(card.id) failed (\(r.stdoutData.count) bytes, \(r.stderr.split(separator: "\n").first.map(String.init) ?? ""))")
            return nil
        }
        return cg
    }

    // MARK: - Drawing

    struct Layout {
        let scale: CGFloat
        let origin: CGPoint
        func rect(_ f: BoardCard.Frame) -> CGRect {
            CGRect(x: origin.x + f.x * scale, y: origin.y + f.y * scale,
                   width: max(2, f.width * scale), height: max(2, f.height * scale))
        }
    }

    /// Bounding box of all cards fitted (aspect preserved, centred, never enlarged past 1:1)
    /// into the canvas with a small margin.
    static func layout(_ rows: [BoardCard], size: CGSize = size) -> Layout {
        let frames = rows.map { CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height) }
        guard let bounds = frames.dropFirst().reduce(frames.first, { $0?.union($1) }), bounds.width > 0, bounds.height > 0 else {
            return Layout(scale: 1, origin: .zero)
        }
        let inset: CGFloat = 6
        let avail = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let scale = min(1, avail.width / bounds.width, avail.height / bounds.height)
        let origin = CGPoint(x: avail.midX - bounds.width * scale / 2 - bounds.minX * scale,
                             y: avail.midY - bounds.height * scale / 2 - bounds.minY * scale)
        return Layout(scale: scale, origin: origin)
    }

    struct Drawn {
        let image: NSImage
        let png: Data
    }

    /// Renders `rows` (lowest zOrder first) into a `size`-pixel bitmap. Pure CPU; safe on any
    /// thread because it draws into its own NSGraphicsContext.
    static func draw(rows: [BoardCard], pictures: [String: CGImage], size: CGSize) -> Drawn? {
        let w = Int(size.width), h = Int(size.height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size // 1 pt = 1 px
        let cg = base.cgContext
        // Top-left origin like Allume's coordinates; `flipped: true` keeps AppKit text upright.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        let ctx = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()

        let layout = layout(rows, size: size)
        let ordered = rows.enumerated().sorted { a, b in
            let za = a.element.zOrder ?? 0, zb = b.element.zOrder ?? 0
            return za != zb ? za < zb : a.offset < b.offset
        }.map(\.element)
        for row in ordered {
            drawCard(row, in: layout.rect(row.frame), scale: layout.scale, picture: pictures[row.id], cg: cg)
        }
        cg.flush()

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return Drawn(image: image, png: png)
    }

    private static let cardStroke = NSColor(white: 0.80, alpha: 1)
    private static let greyBlock = NSColor(white: 0.86, alpha: 1)
    private static let subBoardFill = NSColor(white: 0.90, alpha: 1)
    private static let urlFill = NSColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1)
    private static let ink = NSColor(white: 0.25, alpha: 1)
    private static let faintInk = NSColor(white: 0.45, alpha: 1)

    /// Type size for body text: Allume's ~16 pt body shrunk with the board, clamped to 2–3 pt so
    /// it reads as a block of text, never as legible words.
    private static func bodyFontSize(_ scale: CGFloat) -> CGFloat { min(3, max(2, 16 * scale)) }

    private static func drawCard(_ row: BoardCard, in r: CGRect, scale: CGFloat, picture: CGImage?, cg: CGContext) {
        let radius = min(3, max(1, r.width * 0.03))
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        let kind = row.kind ?? ""
        switch kind {
        case "text", "chain":
            NSColor.white.setFill(); path.fill()
            cardStroke.setStroke(); path.lineWidth = 0.5; path.stroke()
            drawBody(row.document?.body, in: r, fontSize: bodyFontSize(scale), color: ink, cg: cg)
        case "url":
            urlFill.setFill(); path.fill()
            cardStroke.setStroke(); path.lineWidth = 0.5; path.stroke()
            drawTitle(row.title, in: r, fontSize: min(3.5, max(2.5, 18 * scale)), color: ink, weight: .semibold, cg: cg)
        case "image":
            if let picture {
                drawPicture(picture, in: r, path: path, fill: true, cg: cg)
            } else {
                greyBlock.setFill(); path.fill()
            }
        case "pdf":
            if let picture {
                NSColor.white.setFill(); path.fill()
                drawPicture(picture, in: r, path: path, fill: false, cg: cg)
                cardStroke.setStroke(); path.lineWidth = 0.5; path.stroke()
            } else {
                greyBlock.setFill(); path.fill()
                drawIcon("doc.fill", in: r, cg: cg)
            }
        case "subBoard":
            subBoardFill.setFill(); path.fill()
            cardStroke.setStroke(); path.lineWidth = 0.5; path.stroke()
            drawTitle(row.title, in: r, fontSize: min(4, max(2.5, 20 * scale)), color: faintInk, weight: .medium, cg: cg)
        case "video":
            greyBlock.setFill(); path.fill()
            drawIcon("play.fill", in: r, cg: cg)
        default: // file and anything new
            greyBlock.setFill(); path.fill()
            drawIcon("doc.fill", in: r, cg: cg)
        }
    }

    /// Body text wrapped into the card at `fontSize`, clipped to the card.
    private static func drawBody(_ body: String?, in r: CGRect, fontSize: CGFloat, color: NSColor, cg: CGContext) {
        guard let body, !body.isEmpty else { return }
        let text = String(body.prefix(maxBodyLength))
        let pad = max(0.5, r.width * 0.05)
        let box = r.insetBy(dx: pad, dy: pad)
        guard box.width > 1, box.height > 1 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        cg.saveGState()
        cg.clip(to: box)
        NSAttributedString(string: text, attributes: attrs).draw(with: box, options: [.usesLineFragmentOrigin])
        cg.restoreGState()
    }

    /// One line of title text at the top of the card, truncated to its width.
    private static func drawTitle(_ title: String?, in r: CGRect, fontSize: CGFloat, color: NSColor, weight: NSFont.Weight, cg: CGContext) {
        guard let title, !title.isEmpty else { return }
        let pad = max(0.5, r.width * 0.05)
        let box = CGRect(x: r.minX + pad, y: r.minY + pad, width: r.width - 2 * pad, height: fontSize * 1.4)
        guard box.width > 1, r.height > fontSize else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        cg.saveGState()
        cg.clip(to: r)
        NSAttributedString(string: title, attributes: attrs).draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        cg.restoreGState()
    }

    /// `fill`: aspect-fill (image cards, cropped by the rounded rect); else aspect-fit (PDF pages).
    private static func drawPicture(_ picture: CGImage, in r: CGRect, path: NSBezierPath, fill: Bool, cg: CGContext) {
        let pw = CGFloat(picture.width), ph = CGFloat(picture.height)
        guard pw > 0, ph > 0 else { return }
        let s = fill ? max(r.width / pw, r.height / ph) : min(r.width / pw, r.height / ph)
        let target = CGRect(x: r.midX - pw * s / 2, y: r.midY - ph * s / 2, width: pw * s, height: ph * s)
        cg.saveGState()
        path.addClip()
        // The context is flipped (y down); CGImage drawing assumes y up, so flip back around the target.
        cg.translateBy(x: 0, y: target.midY * 2)
        cg.scaleBy(x: 1, y: -1)
        cg.interpolationQuality = .medium
        cg.draw(picture, in: target)
        cg.restoreGState()
    }

    /// A faint SF Symbol centred in the card (video / file / unfetched PDF).
    private static func drawIcon(_ name: String, in r: CGRect, cg: CGContext) {
        let edge = min(r.width, r.height) * 0.4
        guard edge >= 3,
              let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [faintInk])) else { return }
        let box = CGRect(x: r.midX - edge / 2, y: r.midY - edge / 2, width: edge, height: edge)
        symbol.draw(in: box, from: .zero, operation: .sourceOver, fraction: 0.7, respectFlipped: true, hints: nil)
    }

    private static func ms(since t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
}
