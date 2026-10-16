import Foundation
import Combine

struct CardSummary: Identifiable, Equatable {
    let id: String
    var title: String
    var kind: String
}

/// Shared observable state for the overlay views.
@MainActor
final class AppState: ObservableObject {
    @Published var axTrusted = false
    @Published var allumeRunning = false
    @Published var boardTitle = ""
    @Published var selectedCardIds: [String] = []
    /// Titles/kinds of the selected cards, filled in asynchronously after ⌘K for the card stack.
    @Published var selectedCards: [CardSummary] = []
    @Published var selectionMessage = ""
    @Published var log = ""
    @Published var isRunning = false
    /// One-line result of the last command, shown under the buttons (the full CLI transcript
    /// goes to `log` and ~/Library/Logs/AllumeCompanion.log).
    @Published var status = ""
    @Published var columns = 3
    /// Name of the step the "撤销" button would revert; nil when there is nothing to undo.
    @Published var undoLabel: String?

    func appendLog(_ s: String) {
        Log.info("panel: " + s.trimmingCharacters(in: .whitespacesAndNewlines))
        log += s.hasSuffix("\n") ? s : s + "\n"
        if log.count > 20_000 { log = String(log.suffix(15_000)) }
    }
}
