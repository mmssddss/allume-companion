import Foundation

/// Polls Allume's `lastViewedDocumentId` preference and resolves it to a board title.
///
/// Allume is sandboxed, so its defaults live in its container and CFPreferences cannot read
/// them cross-app; we read the plist file directly (same data `defaults read` shows).
/// Titles come from a one-time BFS crawl of the workspace (board-content --kinds subBoard),
/// because no CLI command returns a board's title from its id alone.
@MainActor
final class BoardWatcher {
    static let plistPath = NSString(string:
        "~/Library/Containers/com.musesoftware.museios-setapp/Data/Library/Preferences/com.musesoftware.museios-setapp.plist"
    ).expandingTildeInPath

    var onChange: ((_ id: String, _ title: String) -> Void)?

    private var timer: Timer?
    private var currentId = ""
    private var titles: [String: String] = [:]
    private var crawlTask: Task<Void, Never>?
    private var lastCrawl = Date.distantPast

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    static func readLastViewedDocumentId() -> String? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dict["lastViewedDocumentId"] as? String
    }

    private func tick() {
        guard let id = Self.readLastViewedDocumentId(), id != currentId else { return }
        currentId = id
        if let title = titles[id] {
            onChange?(id, title)
        } else {
            onChange?(id, "")
            crawlIfStale()
        }
    }

    /// Crawl at most once per 30 s (a miss usually means a board that did not exist at last crawl).
    private func crawlIfStale() {
        guard crawlTask == nil, Date().timeIntervalSince(lastCrawl) > 30 else { return }
        lastCrawl = Date()
        crawlTask = Task { [weak self] in
            let map = await Task.detached(priority: .utility) { Self.crawlTitles() }.value
            guard let self else { return }
            self.titles.merge(map) { _, new in new }
            self.crawlTask = nil
            if let t = self.titles[self.currentId] { self.onChange?(self.currentId, t) }
        }
    }

    nonisolated static func crawlTitles() -> [String: String] {
        var titles: [String: String] = [:]
        let ws = AllumeCLI.runSync(["list-workspaces", "--format", "json"])
        guard let wsData = ws.stdout.data(using: .utf8),
              let workspaces = try? JSONSerialization.jsonObject(with: wsData) as? [[String: Any]] else { return titles }
        var queue: [String] = []
        for w in workspaces {
            let name = w["title"] as? String ?? "Workspace"
            if let root = w["rootBoardId"] as? String { titles[root] = name; queue.append(root) }
            if let inbox = w["inboxId"] as? String { titles[inbox] = "\(name) · 收件箱"; }
            if let pinbox = w["personalInboxId"] as? String { titles[pinbox] = "个人收件箱" }
        }
        var i = 0
        while i < queue.count {
            let board = queue[i]; i += 1
            let r = AllumeCLI.runSync(["board-content", board, "--kinds", "subBoard", "--format", "json"])
            guard let d = r.stdout.data(using: .utf8),
                  let cards = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { continue }
            for c in cards {
                guard let doc = c["document"] as? [String: Any], let id = doc["id"] as? String else { continue }
                if titles[id] == nil {
                    titles[id] = (doc["title"] as? String) ?? (c["title"] as? String) ?? "(无标题)"
                    queue.append(id)
                }
            }
        }
        return titles
    }
}
