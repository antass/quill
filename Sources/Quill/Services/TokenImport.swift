import Foundation

/// Escape hatch for getting a token in without the settings UI: drop the token into
/// ~/Library/Application Support/Quill/notion-token.txt and Quill imports it on launch
/// (or whenever Settings opens), writes it to the Keychain itself, and deletes the file.
enum TokenImport {

    static var dropURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quill", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("notion-token.txt")
    }

    /// Returns a message when something was imported (or failed), else nil.
    @discardableResult
    static func importIfPresent() -> String? {
        let url = dropURL
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove the file whatever happens — it must not linger in plain text.
        defer { try? FileManager.default.removeItem(at: url) }

        guard token.count > 20 else {
            Diag.log("token-import: file present but content too short (\(Diag.shape(token)))")
            return "The token file didn't contain a usable token."
        }
        if let error = Keychain.set(token, for: "notion-token") {
            Diag.log("token-import: keychain write FAILED \(error)")
            return error
        }
        Diag.log("token-import: stored token \(Diag.shape(token))")
        return "Imported your token from notion-token.txt."
    }
}
