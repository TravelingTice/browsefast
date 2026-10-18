import Foundation

// Session log at ~/Library/Logs/BrowseFast/session.log. Agents read this to see how a run went,
// so log every meaningful step. Never log API keys or anything typed into password fields.
public enum Log {
    public static let fileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/BrowseFast/session.log")

    private static let queue = DispatchQueue(label: "app.browsefast.log")
    private static let maxBytes = 10_000_000

    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    public static func startSession() {
        queue.sync {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // ponytail: single-step rotation, keeps one previous file; add more generations if logs need longer history.
            if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > maxBytes {
                let previous = fileURL.deletingPathExtension().appendingPathExtension("1.log")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: fileURL, to: previous)
            }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        append("\n" + line("session", "===== New session started (pid \(ProcessInfo.processInfo.processIdentifier), macOS \(os)) ====="))
    }

    /// One timestamped line, plus an optional indented multi-line block underneath.
    public static func write(_ category: String, _ message: String, details: String? = nil) {
        var text = line(category, message)
        if let details, !details.isEmpty {
            text += "\n" + details.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    " + $0 }
                .joined(separator: "\n")
        }
        append(text)
    }

    private static func line(_ category: String, _ message: String) -> String {
        "\(timestamp.string(from: Date())) [\(category)] \(message)"
    }

    private static func append(_ text: String) {
        queue.async {
            let data = Data((text + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
