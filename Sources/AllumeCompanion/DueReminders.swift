import AppKit
import UserNotifications

/// The 设置 window's reminder options, in UserDefaults: on/off and the time of day (default 09:00).
enum ReminderSettings {
    private static let d = UserDefaults.standard
    static func registerDefaults() {
        d.register(defaults: ["reminders.enabled": true, "reminders.hour": 9, "reminders.minute": 0])
    }
    static var enabled: Bool {
        get { d.bool(forKey: "reminders.enabled") }
        set { d.set(newValue, forKey: "reminders.enabled") }
    }
    static var hour: Int {
        get { d.integer(forKey: "reminders.hour") }
        set { d.set(newValue, forKey: "reminders.hour") }
    }
    static var minute: Int {
        get { d.integer(forKey: "reminders.minute") }
        set { d.set(newValue, forKey: "reminders.minute") }
    }
    /// When the reminder for a todo due on `day` goes off.
    static func fireDate(on day: Date) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}

/// System notifications for `@todo(due: YYYY-MM-DD)` cards. The CLI knows no time at all,
/// so this is the companion's job alone: each dated todo gets one notification on its day at
/// the time set in 设置 (`ReminderSettings`, default 09:00; `UNCalendarNotificationTrigger`);
/// one already due fires once, now. Turned off in 设置, nothing is pending. Clicking the banner
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
                Log.info("reminders: authorization status \(settings.authorizationStatus.rawValue) (0 = not asked yet, 1 = denied, 2 = allowed); alert \(settings.alertSetting.rawValue), banner-in-center \(settings.notificationCenterSetting.rawValue), sound \(settings.soundSetting.rawValue)")
                if settings.authorizationStatus == .denied {
                    Log.info("reminders: notifications are off for this app; turn on 允许通知 in 系统设置 → 通知 → Allume Companion (设置窗口里有按钮)")
                }
                if Self.isAllowed(settings) {
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

    /// Settings changed (on/off, time): drop every pending reminder and schedule again.
    func reschedule(_ todos: [TodoItem]) {
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            Task { @MainActor in
                Log.info("reminders: settings changed (\(ReminderSettings.enabled ? String(format: "on, %02d:%02d", ReminderSettings.hour, ReminderSettings.minute) : "off")); removed \(ours.count) pending")
                self.schedule(todos)
            }
        }
    }

    /// Reconciles pending notifications with the current todo list.
    func schedule(_ todos: [TodoItem]) {
        guard Self.available else { return }
        guard ReminderSettings.enabled else { removeAllPending(); return }
        let center = UNUserNotificationCenter.current()
        // Asked live, so flipping the switch in 系统设置 takes effect at the next scan, no relaunch.
        center.getNotificationSettings { [weak self] settings in
            let ok = Self.isAllowed(settings)
            Task { @MainActor in
                guard let self else { return }
                self.authorized = ok
                if ok { self.reconcile(todos, center: center) }
            }
        }
    }

    /// Turned off: nothing of ours stays pending.
    private func removeAllPending() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { pending in
            let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
            if !ours.isEmpty { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ours) }
        }
    }

    /// Only `authorizationStatus` says whether anything will show. `alertSetting` can read
    /// enabled while 允许通知 is off: `add` then succeeds and usernoted presents the notification
    /// "as none" (its log: `notificationsAllowed: false`), so nothing appears.
    nonisolated static func isAllowed(_ s: UNNotificationSettings) -> Bool {
        s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
    }

    /// What 设置 shows next to 通知: whether this app may post them.
    enum Permission { case unavailable, allowed, denied, notAsked }
    static func permission() async -> Permission {
        guard available else { return .unavailable }
        let s = await UNUserNotificationCenter.current().notificationSettings()
        if isAllowed(s) { return .allowed }
        return s.authorizationStatus == .notDetermined ? .notAsked : .denied
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
            guard let day = t.due else { continue }
            let due = ReminderSettings.fireDate(on: day)
            let key = t.cardId + "|" + Self.dayKey.string(from: day)
            let id = Self.idPrefix + t.cardId
            let content = UNMutableNotificationContent()
            content.title = t.label
            content.body = (t.dueLabel.map { "\($0) · " } ?? "") + String(localized: "白板：\(t.boardTitle)")
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

    /// 设置 "发一条测试通知": checks the permission first (a denied app's notification is accepted
    /// and then silently dropped), asks for it if never asked, then delivers one now. `done`
    /// gets a line for the 设置 window saying what happened.
    func sendTest(done: @escaping @MainActor (String) -> Void = { _ in }) {
        guard Self.available else { Log.info("reminders: test skipped, not in an .app bundle"); done(String(localized: "只在打包好的 .app 里能发通知")); return }
        Task { @MainActor in
            var permission = await Self.permission()
            if permission == .notAsked {
                let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                permission = ok ? .allowed : .denied
            }
            guard permission == .allowed else {
                Log.info("reminders: test not sent, notifications are off for this app")
                done(String(localized: "通知被关掉了：在系统设置 → 通知 → Allume Companion 里打开「允许通知」"))
                return
            }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Allume Companion 测试通知")
            content.body = String(localized: "能看到这条，到期提醒就能响。")
            content.sound = .default
            do {
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
                Log.info("reminders: test notification handed to the system")
                done(String(localized: "已发出，看屏幕右上角；没看到就检查专注模式"))
            } catch {
                Log.info("reminders: test notification failed: \(error.localizedDescription)")
                done(String(localized: "发送失败：\(error.localizedDescription)"))
            }
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
