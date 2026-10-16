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
        let stderr: String
        var ok: Bool { status == 0 }
    }

    static func run(_ args: [String]) async -> Result {
        await Task.detached(priority: .userInitiated) { runSync(args) }.value
    }

    /// Resolved path of the real executable (open(1) needs the binary, not the symlink).
    static var executable: String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
    }

    static func runSync(_ args: [String]) -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return Result(status: -1, stdout: "", stderr: "找不到 \(path)（在 Allume → Preferences → Command Line 里安装）")
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
            return Result(status: -1, stdout: "", stderr: "无法启动 open: \(error.localizedDescription)")
        }
        let openErrText = String(decoding: openErr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let o = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        let e = ((try? String(contentsOf: err, encoding: .utf8)) ?? "") + openErrText
        // open(1) does not relay the CLI's exit status (it is 0 even when the CLI printed an
        // error), so treat an "error:" line on stderr as failure.
        var status = p.terminationStatus
        if status == 0, e.lowercased().contains("error") { status = 1 }
        return Result(status: status, stdout: o, stderr: e)
    }

    /// Shell-style rendering of a command line for the log.
    static func render(_ args: [String]) -> String {
        "$ allume " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}
