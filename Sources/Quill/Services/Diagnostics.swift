import Foundation

/// Appends to ~/Library/Application Support/Quill/diagnostics.log so a UI problem can be
/// diagnosed from the outside. Never records the token itself — only its shape.
enum Diag {
    private static let queue = DispatchQueue(label: "com.ania.quill.diag")

    static var logURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quill", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("diagnostics.log")
    }

    static func log(_ message: String) {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(stamp)  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    /// Describes a secret without leaking it.
    static func shape(_ secret: String) -> String {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        return "len=\(trimmed.count) prefix=\(trimmed.prefix(4))…"
    }
}
