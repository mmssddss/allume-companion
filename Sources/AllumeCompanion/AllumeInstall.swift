import AppKit

/// Is Allume there, and which one? Everything the companion does goes through Allume's CLI, so
/// both the app and `/usr/local/bin/allume` have to be installed.
///
/// The app is found from the CLI symlink: it points into the app that installed it
/// (`…/Allume.app/Contents/MacOS/allume-cli`), so its bundle id is the edition the user has
/// (Setapp's is `com.musesoftware.museios-setapp`; other editions have their own). Without the
/// CLI, `Allume.app` is looked for in the usual places. Not by the old name: a `Muse.app` can be
/// an unrelated app.
struct AllumeSetup: Equatable {
    /// The Allume.app found, if any.
    var appURL: URL?
    var bundleID: String?
    var cliInstalled = false

    var appInstalled: Bool { appURL != nil }
    var ready: Bool { appInstalled && cliInstalled }

    static let website = URL(string: "https://allume.com")!
    static let fallbackBundleID = "com.musesoftware.museios-setapp"

    static func detect() -> AllumeSetup {
        var s = AllumeSetup()
        let fm = FileManager.default
        let cli = URL(fileURLWithPath: AllumeCLI.path).resolvingSymlinksInPath()
        s.cliInstalled = fm.isExecutableFile(atPath: cli.path)
        if s.cliInstalled, let app = enclosingApp(of: cli) {
            s.appURL = app
        } else {
            let home = fm.homeDirectoryForCurrentUser.path
            s.appURL = ["/Applications/Allume.app", "/Applications/Setapp/Allume.app", home + "/Applications/Allume.app"]
                .map { URL(fileURLWithPath: $0) }
                .first { fm.fileExists(atPath: $0.path) }
        }
        s.bundleID = s.appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        // Test hook: `ALLUME_FAKE_SETUP=noapp|nocli` pretends that part is missing (`readonly`:
        // the write-mode probe answers read-only).
        switch ProcessInfo.processInfo.environment["ALLUME_FAKE_SETUP"] {
        case "noapp": s.appURL = nil; s.bundleID = nil; s.cliInstalled = false
        case "nocli": s.cliInstalled = false
        default: break
        }
        return s
    }

    /// The `.app` a file sits in (`…/Allume.app/Contents/MacOS/allume-cli` → `…/Allume.app`).
    private static func enclosingApp(of url: URL) -> URL? {
        var u = url
        while u.path != "/" {
            if u.pathExtension == "app" { return u }
            u = u.deletingLastPathComponent()
        }
        return nil
    }

    /// Allume's CLI is read-only until the user switches it in Allume (Allume 设置 → CLI → read-write); every arrange/resize/add-todo command needs it writable. There is no
    /// command that reports the mode and its preference file is not readable from here, so ask
    /// with a write that cannot change anything: `card-move` on an id that does not exist. A
    /// read-only CLI refuses before looking ("…the CLI is in read-only mode"), a writable one
    /// answers "No card or chain with id …". Anything else (Allume not running, a timeout) is
    /// `.unknown`. Needs Allume running.
    enum WriteMode: Equatable { case unknown, writable, readOnly }

    static func probeWriteMode() async -> WriteMode {
        let none = "00000000000000000000000000000000:00000000000000000000000000000000"
        let r = await AllumeCLI.run(["card-move", "--id", none, "--x", "0", "--y", "0", "--format", "json"], background: true)
        var mode: WriteMode = isReadOnlyError(r.stderr) ? .readOnly : r.stderr.contains("No card") ? .writable : .unknown
        if ProcessInfo.processInfo.environment["ALLUME_FAKE_SETUP"] == "readonly" { mode = .readOnly }
        Log.info("allume setup: CLI write mode \(mode) (\(r.stderr.split(separator: "\n").first ?? "no stderr"))")
        return mode
    }

    static func isReadOnlyError(_ stderr: String) -> Bool { stderr.contains("read-only mode") }

    /// One line for the log.
    var summary: String {
        "app \(appURL?.path ?? "missing") (\(bundleID ?? "-")), CLI \(cliInstalled ? "ok" : "missing")"
    }
}
