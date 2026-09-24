import Foundation
import Observation
import WTInterchange
import WTModel

/// How one export ended.
enum ExportOutcome: Equatable, Sendable {
    /// Written: every file and the summary's notes.
    case exported(ExportSummary)
    /// Cancelled; nothing was left on disk.
    case cancelled
    /// Refused before anything was written, or failed while writing: the message to show.
    case failed(String)
}

/// A running export as the window shows it: the fraction done (nil while the exporter cannot
/// say) and Cancel.
@MainActor
@Observable
final class ExportActivity {
    let title: String
    let progress: ExportProgress
    /// 0 ... 1, nil for an exporter that reports no progress.
    private(set) var fraction: Double?
    private(set) var isCancelled = false

    init(title: String, reportsProgress: Bool) {
        self.title = title
        fraction = reportsProgress ? 0 : nil
        let box = FractionBox()
        progress = ExportProgress { value in box.send(value) }
        box.receive = { [weak self] value in self?.fraction = value }
    }

    /// The sheet's btn:[Cancel].
    func cancel() {
        isCancelled = true
        progress.cancel()
    }
}

/// Carries the exporter's fractions from its thread to the main actor.
final class FractionBox: @unchecked Sendable {
    var receive: @MainActor (Double) -> Void = { _ in }

    func send(_ value: Double) {
        Task { @MainActor [self] in receive(value) }
    }
}

/// The export itself (exporting.adoc, "Client"): the snapshot taken on the main actor is written
/// by the format's exporter on a background task into a staging folder next to the destination,
/// and only a finished export moves into place, so a cancelled or failed one -- one file or a
/// set -- leaves nothing behind.
enum ExportPipeline {
    /// Writes `snapshot` with `exporter` to `destination`.  Cancelling the calling task or
    /// `progress` stops it and throws `ExportError.cancelled`.
    static func run(_ snapshot: ExportSnapshot, exporter: any Exporter, options: any ExportOptions, to destination: ExportDestination,
                    progress: ExportProgress) async throws -> ExportSummary {
        let manager = FileManager.default
        let directory = destination.url.deletingLastPathComponent()
        let staging: URL
        do {
            staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        defer { try? manager.removeItem(at: staging) }
        let staged = ExportDestination(url: staging.appendingPathComponent(destination.url.lastPathComponent), namePattern: destination.namePattern,
                                       date: destination.date)
        let written = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try write(snapshot, exporter: exporter, options: options, to: staged, progress: progress)
            }.value
        } onCancel: {
            progress.cancel()
        }
        guard !progress.isCancelled else { throw ExportError.cancelled }
        return try move(written, from: staging, to: directory)
    }

    /// The export proper, off the main actor.
    nonisolated static func write(_ snapshot: ExportSnapshot, exporter: any Exporter, options: any ExportOptions, to destination: ExportDestination,
                                  progress: ExportProgress) throws -> ExportSummary {
        guard !progress.isCancelled else { throw ExportError.cancelled }
        let scene = try snapshot.resolved()
        if var animation = exporter as? AnimationExporter {
            animation.progress = progress
            return try animation.export(scene: scene, options: options, to: destination)
        }
        return try exporter.export(scene: scene, options: options, to: destination)
    }

    /// Moves everything the export wrote in `staging` -- its files and any folder beside them
    /// (SVG's linked images) -- into `directory`, replacing what is there.
    static func move(_ summary: ExportSummary, from staging: URL, to directory: URL) throws -> ExportSummary {
        let manager = FileManager.default
        let prefix = staging.standardizedFileURL.path + "/"
        do {
            for item in try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                let target = directory.appendingPathComponent(item.lastPathComponent)
                if manager.fileExists(atPath: target.path) {
                    try manager.removeItem(at: target)
                }
                try manager.moveItem(at: item, to: target)
            }
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        let files = summary.files.map { file in
            directory.appendingPathComponent(String(file.standardizedFileURL.path.dropFirst(prefix.count)))
        }
        return ExportSummary(files: files, notes: summary.notes)
    }
}
