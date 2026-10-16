import Foundation
import Combine

/// Shared observable state for the overlay views.
@MainActor
final class AppState: ObservableObject {
    @Published var axTrusted = false
    @Published var allumeRunning = false
    @Published var boardTitle = ""
    @Published var selectedCardIds: [String] = []
    @Published var selectionMessage = ""
    @Published var log = ""
    @Published var isRunning = false
    @Published var columns = 3
    /// Name of the step the "撤销" button would revert; nil when there is nothing to undo.
    @Published var undoLabel: String?

    func appendLog(_ s: String) {
        log += s.hasSuffix("\n") ? s : s + "\n"
        if log.count > 20_000 { log = String(log.suffix(15_000)) }
    }
}
