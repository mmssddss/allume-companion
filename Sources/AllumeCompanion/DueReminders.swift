import AppKit
import UserNotifications

/// System notifications for `@todo` cards whose body names a date. The CLI knows no time at all,
/// so this is the companion's job alone: each dated todo gets one notification at 09:00 on its
/// day (`UNCalendarNotificationTrigger`); one already due fires once, now. Clicking the banner
/// runs `allume open <board>` and brings Allume forward. Which (card, due day) pairs were already
/// delivered is remembered in reminders.json so a scan never re-fires them.
@MainActor
final class DueReminders: NSObject, UNUserNotificationCenterDelegate {
    static let fileURL = BoardIndex.fileURL.deletingLastPathComponent().appendingPathComponent("reminders.json")
    private static let idPrefix = "due-"

    /// `cardId|yyyy-MM-dd` pairs delivered already.
    private var delivered: Set<String> = []
    private var authorized = false
    /// Set by AppDelegate: opens a board (CLI) and activates Allume.
    var openBoard: ((String, String) -> Void)?
    /// Set by AppDelegate: permission is in; schedule what the todo index has.
    var onAuthorized: (() -> Void)?

    /// Only meaningful inside the .app bundle: `UNUserNotificationCenter` needs a bundle id.
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    override init() {
        super.init()
        if let data = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode([String].self, from: data) { delivered = Set(s) }
    }

    func start() {
        guard Self.available else { Log.info("reminders: not in an .app bundle, notifications off"); return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                Log.info("reminders: authorization status \(settings.authorizationStatus.rawValue) (0 = not asked yet, 1 = denied, 2 = allowed)")
                if settings.authorizationStatus == .denied {
                    Log.info("reminders: notifications are off for this app; turn them on in 系统设置 → 通知 → Allume Companion (menu: 打开通知设置…)")
                }
                if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                    self.authorized = true
                    self.onAuthorized?()
                    return
                }
                guard settings.authorizationStatus == .notDetermined else { return }
                // The system asks the user once; until they answer, nothing is scheduled.
                center.requestAuthorization(options: [.alert, .sound]) { ok, err in
                    Task { @MainActor in
                        self.authorized = ok
                        Log.info("reminders: notifications \(ok ? "allowed" : "denied")\(err.map { " (\($0.localizedDescription))" } ?? "")")
                        if ok { self.onAuthorized?() }
                    }
                }
            }
        }
    }

    private static let dayKey: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    /// Reconciles pending notifications with the current todo list.
    func schedule(_ todos: [TodoItem]) {
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        // Asked live, so flipping the switch in 系统设置 takes effect at the next scan, no relaunch.
        center.getNotificationSettings { [weak self] settings in
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in
                guard let self else { return }
                self.authorized = ok
                if ok { self.reconcile(todos, center: center) }
            }
        }
    }

    private func reconcile(_ todos: [TodoItem], center: UNUserNotificationCenter) {
        let dated = todos.filter { $0.due != nil }
        let wanted = Set(dated.map { Self.idPrefix + $0.cardId })
        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) && !wanted.contains($0) }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
            Task { @MainActor in self.add(dated, center: center, pendingIds: Set(pending.map(\.identifier))) }
        }
    }

    private func add(_ dated: [TodoItem], center: UNUserNotificationCenter, pendingIds: Set<String>) {
        var fired = 0, queued = 0
        for t in dated {
            guard let due = t.due else { continue }
            let key = t.cardId + "|" + Self.dayKey.string(from: due)
            let id = Self.idPrefix + t.cardId
            let content = UNMutableNotificationContent()
            content.title = t.label
            content.body = (t.dueLabel.map { "\($0) · " } ?? "") + "白板：\(t.boardTitle)"
            content.sound = .default
            content.userInfo = ["boardId": t.boardId, "boardTitle": t.boardTitle, "cardId": t.cardId]
            if due > Date() {
                if pendingIds.contains(id) { continue } // same card, same day: already queued
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
                queued += 1
            } else if !delivered.contains(key) {
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                delivered.insert(key)
                fired += 1
            }
        }
        if fired + queued > 0 {
            save()
            Log.info("reminders: \(fired) due now, \(queued) scheduled (\(dated.count) dated todos)")
        }
    }

    /// Opens this app's page in 系统设置 → 通知.
    static func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(delivered).sorted()) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let boardId = info["boardId"] as? String else { return }
        let title = info["boardTitle"] as? String ?? ""
        await MainActor.run { self.openBoard?(boardId, title) }
    }
}
