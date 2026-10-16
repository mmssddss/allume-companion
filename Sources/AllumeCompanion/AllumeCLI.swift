import Foundation

/// Runs /usr/local/bin/allume as a subprocess and captures its output.
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

    static func runSync(_ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return Result(status: -1, stdout: "", stderr: "无法启动 \(path): \(error.localizedDescription)")
        }
        // Drain both pipes before waiting so a chatty command cannot deadlock.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Shell-style rendering of a command line for the log.
    static func render(_ args: [String]) -> String {
        "$ allume " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}
