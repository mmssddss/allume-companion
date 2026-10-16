import AppKit
import Combine

struct CardSummary: Identifiable, Equatable {
    let id: String
    var title: String
    var kind: String
    /// First few dozen characters of a text/chain card's body (shown instead of a picture).
    var excerpt: String = ""
    /// For subBoard cards: the board document id (`document.id`), what `board-content` wants.
    var documentId: String?
    /// Filled in asynchronously by ThumbnailLoader for image / pdf / subBoard cards.
    var thumbnail: NSImage?

    static func == (a: CardSummary, b: CardSummary) -> Bool {
        a.id == b.id && a.title == b.title && a.kind == b.kind && a.excerpt == b.excerpt
            && a.documentId == b.documentId && a.thumbnail === b.thumbnail
    }
}

/// Shared observable state for the overlay views.
@MainActor
final class AppState: ObservableObject {
    @Published var axTrusted = false
    @Published var allumeRunning = false
    @Published var boardTitle = ""
    @Published var selectedCardIds: [String] = []
    /// True between ⌘K and the clipboard answer: the panel is already up and lists every
    /// command as if cards were selected, so it never waits for Allume.
    @Published var selectionPending = false
    /// True when `selectedCardIds` came from Allume via ⌘C (so the cards are on the current
    /// board); false for the `ALLUME_SELECT_IDS` test preset, which may name cards anywhere.
    var selectionFromAllume = false
    /// Titles/kinds/thumbnails of the selected cards, filled in asynchronously after ⌘K for the card stack.
    @Published var selectedCards: [CardSummary] = []
    @Published var selectionMessage = ""
    @Published var log = ""
    @Published var isRunning = false
    /// One-line result of the last command, shown under the buttons (the full CLI transcript
    /// goes to `log` and ~/Library/Logs/AllumeCompanion.log).
    @Published var status = ""
    /// Whether `status` reports a failure (the footer shows a warning sign instead of a check).
    @Published var statusIsError = false
    @Published var columns = 3
    /// Name of the step the "撤销" button would revert; nil when there is nothing to undo.
    @Published var undoLabel: String?
    /// Which list the panel shows: the commands, or one of the two navigation lists.
    enum PanelMode: Equatable { case commands, recentBoards, allTodos }
    @Published var panelMode: PanelMode = .commands
    /// Boards visited, most recent first, without the current one (VisitTrail; refreshed on switch).
    @Published var recentBoards: [VisitTrail.Visit] = []
    /// Every @todo card in the workspace, due first (TodoIndex.sorted).
    @Published var todos: [TodoItem] = []
    /// Set by AppDelegate: closes the panel (a jump command leaves it).
    var requestHidePanel: (() -> Void)?

    func setStatus(_ s: String, error: Bool = false) {
        status = s
        statusIsError = error
    }

    func appendLog(_ s: String) {
        Log.info("panel: " + s.trimmingCharacters(in: .whitespacesAndNewlines))
        log += s.hasSuffix("\n") ? s : s + "\n"
        if log.count > 20_000 { log = String(log.suffix(15_000)) }
    }
}
