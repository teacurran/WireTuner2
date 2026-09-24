// FONT-026 (interchange half): *Install for Testing* (font-export.adoc, "Installing for testing"):
// the generated font is copied into WireTuner's own folder -- one folder per document -- and
// registered with Core Text for the user, replacing an earlier install of the same file; *Remove
// Test Fonts* unregisters and deletes them.  The app passes the folder
// (`~/Library/Application Support/WireTuner/TestFonts/<document id>/`) and records the returned
// URLs in the local store's `view` table.

import CoreText
import Foundation

/// Registers generated fonts with macOS for testing.
public struct TestFontInstaller: Sendable {
    /// Why an install failed.
    public enum Failure: Error, Hashable, Sendable {
        /// Core Text refused the font (the message is its error's description).
        case registration(String)
    }

    /// The folder test fonts are kept in.
    public let directory: URL
    /// `.user` for the app; tests register for the process only.
    public let scope: CTFontManagerScope

    public init(directory: URL, scope: CTFontManagerScope = .user) {
        self.directory = directory
        self.scope = scope
    }

    /// Writes `data` as `fileName` in the folder and registers it, unregistering an earlier
    /// install of the same file first.  Returns the registered URL.
    @discardableResult
    public func install(_ data: Data, fileName: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            CTFontManagerUnregisterFontsForURL(url as CFURL, scope, nil)
        }
        try data.write(to: url, options: .atomic)
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, scope, &error) else {
            let message = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "unknown"
            try? FileManager.default.removeItem(at: url)
            throw Failure.registration(message)
        }
        return url
    }

    /// *Remove Test Fonts*: unregisters and deletes `urls`.
    public func remove(_ urls: [URL]) {
        for url in urls {
            CTFontManagerUnregisterFontsForURL(url as CFURL, scope, nil)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
