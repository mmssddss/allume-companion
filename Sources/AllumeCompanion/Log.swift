import Foundation

/// Appends to ~/Library/Logs/AllumeCompanion.log (and stderr) so behaviour can be inspected
/// without Console.app: `tail -f ~/Library/Logs/AllumeCompanion.log`.
enum Log {
    static let path = NSString(string: "~/Library/Logs/AllumeCompanion.log").expandingTildeInPath
    private static let queue = DispatchQueue(label: "log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func info(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
            }
        }
    }
}
