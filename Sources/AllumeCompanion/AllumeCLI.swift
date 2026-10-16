import Foundation

/// Runs the Allume CLI and captures its output.
///
/// The CLI (`Allume.app/Contents/MacOS/allume-cli`, symlinked at /usr/local/bin/allume) is itself
/// sandboxed and decides read-only vs read-write by reading Allume's app-group preferences
/// (`isCLIReadOnly` in ~/Library/Group Containers/group.T68Z94627S.com.musesoftware.museios-setapp).
/// macOS gates group-container access on the *responsible process*: when this app spawns the CLI
/// directly with `Process`, the responsible process is this app, the read is denied, and every
/// write command fails with "the CLI is in read-only mode" (exit 7) even though Preferences say
/// read-write. Launching through LaunchServices (`open -W -n --stdout … -a allume-cli --args …`)
/// makes the CLI its own responsible process, so its own entitlement applies and writes work.
/// Cost: ~150 ms per call instead of ~30 ms.
enum AllumeCLI {
    static let path = "/usr/local/bin/allume"

    struct Result {
        let status: Int32
        let stdout: String
        /// stdout as bytes; only filled when run with `raw: true` (image/PDF bytes), else empty.
        let stdoutData: Data
        let stderr: String
        var ok: Bool { status == 0 }
    }

    /// Running totals, so the ⌘K path can report how many CLI calls it needed. `foreground`
    /// counts calls made on the user's behalf (describing the selection, running a command);
    /// `background` counts the board index crawl, board model refreshes and thumbnail prewarming.
    struct Counts: Equatable {
        var foreground = 0
        var background = 0
        var total: Int { foreground + background }
        static func - (a: Counts, b: Counts) -> Counts {
            Counts(foreground: a.foreground - b.foreground, background: a.background - b.background)
        }
    }
    private static let countsLock = NSLock()
    nonisolated(unsafe) private static var _counts = Counts()
    static var counts: Counts { countsLock.withLock { _counts } }
    private static func count(background: Bool) {
        countsLock.withLock { if background { _counts.background += 1 } else { _counts.foreground += 1 } }
    }

    /// `raw`: keep stdout as bytes (`stdoutData`) instead of decoding it as text — for
    /// `card-content --contents raw` and `card-pdf-page`, which write image bytes to stdout.
    /// `background`: the call is maintenance (crawl, model refresh, prewarm), not something
    /// the user is waiting for; only affects the counters and the log line.
    static func run(_ args: [String], raw: Bool = false, background: Bool = false) async -> Result {
        count(background: background)
        if background { Log.info("cli[bg] " + render(args)) }
        let priority: TaskPriority = background ? .utility : .userInitiated
        var r = await Task.detached(priority: priority) { runSync(args, raw: raw) }.value
        // `open -W` occasionally fails to attach to the process it just launched ("Unable to
        // block on applications"), mostly when several run at once; the CLI itself was fine.
        // One retry, for every caller.
        if !r.ok, r.stderr.contains("Unable to block") {
            Log.info("cli: open -W could not attach (\(r.stderr.split(separator: "\n").first ?? "")), retrying " + render(args))
            count(background: background)
            r = await Task.detached(priority: priority) { runSync(args, raw: raw) }.value
        }
        return r
    }

    /// Resolved path of the real executable (open(1) needs the binary, not the symlink).
    static var executable: String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
    }

    static func runSync(_ args: [String], raw: Bool = false) -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return Result(status: -1, stdout: "", stdoutData: Data(), stderr: "找不到 \(path)（在 Allume → Preferences → Command Line 里安装）")
        }
        let tmp = FileManager.default.temporaryDirectory
        let out = tmp.appendingPathComponent("allume-\(UUID().uuidString).out")
        let err = tmp.appendingPathComponent("allume-\(UUID().uuidString).err")
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: err)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-W", "-n", "--stdout", out.path, "--stderr", err.path, "-a", executable, "--args"] + args
        let openErr = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = openErr
        do { try p.run() } catch {
            return Result(status: -1, stdout: "", stdoutData: Data(), stderr: "无法启动 open: \(error.localizedDescription)")
        }
        let openErrText = String(decoding: openErr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let bytes = (try? Data(contentsOf: out)) ?? Data()
        let o = raw ? "" : String(decoding: bytes, as: UTF8.self)
        let e = ((try? String(contentsOf: err, encoding: .utf8)) ?? "") + openErrText
        // open(1) does not relay the CLI's exit status (it is 0 even when the CLI printed an
        // error), so treat an "error:" line on stderr as failure. With `raw` the stderr is the
        // card's JSON metadata, whose title may legitimately contain "error": judge by the bytes.
        var status = p.terminationStatus
        if status == 0, raw ? bytes.isEmpty : e.lowercased().contains("error") { status = 1 }
        return Result(status: status, stdout: o, stdoutData: raw ? bytes : Data(), stderr: e)
    }

    /// Shell-style rendering of a command line for the log.
    static func render(_ args: [String]) -> String {
        "$ allume " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}
