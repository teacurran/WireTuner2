import Foundation

/// Scratch directories for files the tests write.  Every directory sits under one folder per test
/// process (`WTTextFontTests-<pid>-<uuid>` in `$TMPDIR`), removed when the process exits; folders
/// left by processes that crashed are swept once they are an hour old.  (A directory per test
/// left in `$TMPDIR` piled up by the thousand.)
enum ScratchFolders {
    static let prefix = "WTTextFontTests-"

    /// A fresh, empty directory for one test.
    static func directory() -> URL {
        let url = processRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let processRoot: URL = {
        let temporary = FileManager.default.temporaryDirectory
        sweep(temporary, olderThan: Date().addingTimeInterval(-3600))
        let root = temporary.appending(path: "\(prefix)\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        removeAtExit = root.path
        atexit { if let path = ScratchFolders.removeAtExit { try? FileManager.default.removeItem(atPath: path) } }
        return root
    }()

    nonisolated(unsafe) private static var removeAtExit: String?

    /// Removes the folders with the prefix in `temporary` last modified before `stale`.
    static func sweep(_ temporary: URL, olderThan stale: Date) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            let url = temporary.appending(path: name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < stale { try? FileManager.default.removeItem(at: url) }
        }
    }
}
