import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTModel
import WTProto
import WTRender

/// The *Profiles…* sheet (color-profiles.adoc, "Managing the document's profiles"; CMS-010's app
/// half), opened by the Color Settings sheet's btn:[Profiles…]: every colour profile the document
/// carries, one row per profile however many asset nodes hold it (`ProfileAssets.list`), with its
/// space, size and what uses it -- the working spaces and proof, or the names of images -- and
/// btn:[Export…], which writes the profile's bytes (checked against the asset's hash) to a file.
/// A collaborator's change shows while it is open.
@MainActor
@Observable
final class ProfilesModel {
    /// One row.
    struct Row: Identifiable, Hashable {
        let entry: ProfileAssets.Entry
        let usedBy: String
        var id: Data { entry.id }
        var name: String { entry.name.isEmpty ? "Untitled profile" : entry.name }
        var space: String { ProfilesModel.title(entry.space) }
        var size: String { ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file) }
    }

    static let unused = "Nothing (removed soon)"
    static let unavailable = "The profile's data has not downloaded yet"

    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let close: @MainActor () -> Void
    var selection: Data?
    private(set) var revision = 0
    /// Why the last export failed.
    private(set) var message: String?
    /// A profile's bytes by SHA-256: the registry's (bundled, registered or from the blob cache).
    @ObservationIgnored var bytes: @MainActor (Data) -> Data? = { sha256 in
        WTColor.ProfileRegistry.shared.iccData(for: WTColor.ProfileRef(name: "", sha256: sha256, space: .rgb))
    }
    /// Where btn:[Export…] writes (a save panel); replaceable in tests.
    @ObservationIgnored var chooseDestination: @MainActor (String) async -> URL? = { name in
        let panel = ProfilesModel.savePanel(name)
        return await panel.begin() == .OK ? panel.url : nil
    }
    @ObservationIgnored private var token: DocumentHandle.ObservationToken?

    init(document: DocumentHandle, close: @escaping @MainActor () -> Void) {
        self.document = document
        self.close = close
        token = document.observe { [weak self] _ in self?.revision += 1 }
    }

    func stop() {
        if let token { document.stopObserving(token) }
        token = nil
    }

    nonisolated static func title(_ space: Wiretuner_Doc_V1_ProfileSpace) -> String {
        switch space {
        case .cmyk: "CMYK"
        case .gray: "Gray"
        case .lab: "Lab"
        default: "RGB"
        }
    }

    /// The rows as the document holds them now.
    var rows: [Row] {
        _ = revision
        let state = document.state
        return ProfileAssets.list(state).map { Row(entry: $0, usedBy: Self.usedBy($0.sha256, in: state)) }
    }

    /// What references the profile `sha256`: "Working space" for the document's colour settings,
    /// and the names of the objects (images) that name it; "Nothing (removed soon)" when unused.
    static func usedBy(_ sha256: Data, in state: EngineState) -> String {
        var uses: [String] = []
        for node in state.store.nodes where state.isLive(node) && state.store.kind(node) != ProfileAssets.kind {
            guard ProfileAssets.profiles(in: state.props(node), schema: state.schema).contains(where: { $0.sha256 == sha256 }) else { continue }
            let use = node == WellKnown.settings ? "Working space" : state.displayName(of: node)
            if !uses.contains(use) { uses.append(use) }
        }
        return uses.isEmpty ? unused : uses.joined(separator: ", ")
    }

    /// btn:[Export…]: the selected profile's bytes to a chosen file; the file, or nil (cancelled, or
    /// the bytes are not here or do not match the asset's hash).
    @discardableResult
    func export() async -> URL? {
        message = nil
        guard let row = rows.first(where: { $0.id == selection }), let node = row.entry.nodes.first else { return nil }
        guard let blob = bytes(row.entry.sha256), let data = ProfileAssets.exportData(node, blob: blob, in: document.state) else {
            message = Self.unavailable
            return nil
        }
        guard let url = await chooseDestination("\(row.name).icc") else { return nil }
        do {
            try data.write(to: url)
            return url
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// The save panel btn:[Export…] runs, for a profile file named `name`.
    static func savePanel(_ name: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: "icc")!]
        return panel
    }
}

struct ProfilesSheet: View {
    @Bindable var model: ProfilesModel

    static func export(_ model: ProfilesModel) -> () -> Void { { Task { await model.export() } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profiles").font(.headline)
            Table(model.rows, selection: $model.selection) {
                TableColumn("Name", value: \.name)
                TableColumn("Space", value: \.space)
                TableColumn("Size", value: \.size)
                TableColumn("Used by", value: \.usedBy)
            }
            .frame(minHeight: 180)
            .accessibilityIdentifier("profiles.table")
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.red).accessibilityIdentifier("profiles.message") }
            HStack {
                Button("Export…", action: Self.export(model)).disabled(model.selection == nil).accessibilityIdentifier("profiles.export")
                Spacer()
                Button("Done", action: model.close).keyboardShortcut(.defaultAction).accessibilityIdentifier("profiles.done")
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// The profile reference scan's timer (color-profiles.adoc, "Data model"; the WTSync half CMS-010
/// left, run by the app): every `interval` each open document's `ProfileReferenceScan` looks at
/// its profile assets, and those unreferenced for the retention window are removed
/// (`RemoveUnreferencedProfiles`, not an undo step).
@MainActor
final class ProfileScanTimer {
    static let interval: TimeInterval = 600

    private(set) var scans: [String: ProfileReferenceScan] = [:]
    /// Milliseconds since 1970 now; replaceable in tests.
    var now: @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    private(set) var timer: Timer?

    init() {}

    /// Scans `documents` once: returns the assets removed per document id.
    @discardableResult
    func scan(_ documents: [DocumentHandle]) -> [String: [OpID]] {
        var removed: [String: [OpID]] = [:]
        let time = now()
        for document in documents where document.model != nil && document.canvasNode == nil {
            var scan = scans[document.id] ?? ProfileReferenceScan()
            let due = scan.observe(document.state, now: time)
            scans[document.id] = scan
            guard !due.isEmpty else { continue }
            document.perform(RemoveUnreferencedProfiles(due))
            removed[document.id] = due
        }
        return removed
    }

    /// Starts scanning `documents()` every `interval`.
    func start(_ documents: @escaping @MainActor () -> [DocumentHandle]) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.scan(documents()) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
