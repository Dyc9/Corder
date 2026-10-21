import Foundation

/// Lightweight file logger. NSLog from a `LSUIElement` app launched via `open`
/// does not always reach `log show` or any visible stream, so we additionally
/// append to a stable file we can tail during debugging.
///
/// One handle is kept open on the logger queue (no open/seek/close per line),
/// and the file is rotated to `corder.log.1` past `maxBytes`: the menu-bar app
/// runs for weeks and the log used to grow without bound. It is created 0600,
/// since it carries meeting titles and the account email.
enum FileLogger {
    static let url: URL = URL(fileURLWithPath: "/tmp/corder.log")
    static let rotatedURL: URL = URL(fileURLWithPath: "/tmp/corder.log.1")
    private static let maxBytes: UInt64 = 20 * 1024 * 1024

    private static let queue = DispatchQueue(label: "com.3mpq.corder.logger")
    private static var isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var size: UInt64 = 0

    static func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let stamp = isoFormatter.string(from: Date())
        let line = "\(stamp) \(file):\(line) \(message)\n"
        NSLog("Corder: %@", message)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if size + UInt64(data.count) > maxBytes { rotate() }
            guard let h = openHandle() else { return }
            do {
                try h.write(contentsOf: data)
                size += UInt64(data.count)
            } catch {
                // The handle went bad (file removed under us, disk full):
                // reopen on the next line instead of writing into a dead fd.
                try? h.close()
                handle = nil
            }
        }
    }

    /// Runs on `queue`.
    private static func openHandle() -> FileHandle? {
        if let h = handle { return h }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // Create only when missing: a failed open must never fall back to
            // overwriting the whole log with one line.
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        size = (try? h.seekToEnd()) ?? 0
        handle = h
        return h
    }

    /// Runs on `queue`.
    private static func rotate() {
        try? handle?.close()
        handle = nil
        size = 0
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: url, to: rotatedURL)
    }

    /// The last `maxBytes` of the log as text, read from the end of the file
    /// (never the whole file into memory), invalid UTF-8 replaced instead of
    /// dropping the whole read.
    static func tail(maxBytes: Int = 4 * 1024 * 1024) -> String {
        queue.sync {
            guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? h.close() }
            let end = (try? h.seekToEnd()) ?? 0
            let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
            try? h.seek(toOffset: start)
            let data = (try? h.readToEnd()) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
}
