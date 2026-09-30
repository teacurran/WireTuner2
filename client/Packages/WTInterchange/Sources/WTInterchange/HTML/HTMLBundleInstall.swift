// Putting a published bundle in place (web/publish-html.adoc, "Client"; WEB-009): the bundle is
// written into a hidden sibling of its folder and swapped into place only when every file is
// there, so a cancelled or failed publish leaves the previous bundle (or no folder) and never a
// partial one.

import Foundation

extension HTMLBundle {
    /// The prefix of the hidden sibling a bundle is assembled in: `.<folder name>.publishing-`.
    static func stagingPrefix(_ folder: URL) -> String { ".\(folder.lastPathComponent).publishing-" }

    /// Puts the bundle at `folder` as a whole.  The files are written into a hidden sibling of
    /// `folder`; a file whose bytes the folder already holds is copied from it (keeping its
    /// dates), so republishing changes only what changed.  When every file is written the sibling
    /// replaces `folder` in one swap and the previous bundle -- with anything else that was in the
    /// folder -- goes.  `progress` is told the files done and the file count; between files the
    /// current task's cancellation is checked.  On cancellation or an error the sibling is
    /// removed and `folder` is untouched.  Siblings left by a publish that never finished are
    /// removed first.  Returns the paths whose bytes changed.
    @discardableResult
    public func install(at folder: URL, progress: ((_ done: Int, _ total: Int) -> Void)? = nil) throws -> [String] {
        let manager = FileManager.default
        let parent = folder.deletingLastPathComponent()
        let prefix = Self.stagingPrefix(folder)
        do {
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            for name in (try? manager.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(prefix) {
                try? manager.removeItem(at: parent.appendingPathComponent(name))
            }
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        let staging = parent.appendingPathComponent(prefix + UUID().uuidString)
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            var changed: [String] = []
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let url = staging.appendingPathComponent(file.path)
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let existing = folder.appendingPathComponent(file.path)
                if let bytes = try? Data(contentsOf: existing), bytes == file.data {
                    try manager.copyItem(at: existing, to: url)
                } else {
                    try file.data.write(to: url)
                    changed.append(file.path)
                }
                progress?(index + 1, files.count)
            }
            try Task.checkCancellation()
            try Self.replace(folder, with: staging)
            return changed
        } catch is CancellationError {
            try? manager.removeItem(at: staging)
            throw CancellationError()
        } catch {
            try? manager.removeItem(at: staging)
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    /// Moves `staging` to `folder`: in one atomic swap where the volume offers it, the previous
    /// folder then removed; else the previous folder is moved aside first (a volume without
    /// `RENAME_SWAP`).  `swap` is the swap (replaceable in tests).
    static func replace(_ folder: URL, with staging: URL, swap: (URL, URL) -> Int32 = Self.swap) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.path) else {
            try manager.moveItem(at: staging, to: folder)
            return
        }
        if swap(staging, folder) == 0 {
            // `staging` now holds the previous bundle.
            try? manager.removeItem(at: staging)
            return
        }
        let aside = folder.deletingLastPathComponent().appendingPathComponent(stagingPrefix(folder) + "replaced-" + UUID().uuidString)
        try manager.moveItem(at: folder, to: aside)
        do {
            try manager.moveItem(at: staging, to: folder)
        } catch {
            try? manager.moveItem(at: aside, to: folder)
            throw error
        }
        try? manager.removeItem(at: aside)
    }

    /// `renamex_np(RENAME_SWAP)`: 0 when the two items traded places.
    static func swap(_ first: URL, _ second: URL) -> Int32 {
        first.withUnsafeFileSystemRepresentation { a in
            second.withUnsafeFileSystemRepresentation { b in
                guard let a, let b else { return -1 }
                return renamex_np(a, b, UInt32(RENAME_SWAP))
            }
        }
    }
}
