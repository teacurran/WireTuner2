import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// menu:File[Restore Version…] (history.adoc, "Restoring a version"): the named versions, the
/// state of the chosen one (`VersionStates`: the local log when it can, else the server), the
/// confirmation with `RestoreCommand.summary`'s counts worked out off the main actor, then the
/// restore as one ordinary change that undoes like any other.  *Compare* shows the version against
/// the document in compare mode (*Older* / *Now* / *Overlay*).
@MainActor
@Observable
final class RestoreVersionModel {
    enum Phase: Equatable {
        case choosing
        case loading
        case confirming(RestoreSummary)
        case failed(String)
    }

    let documentTitle: String
    private(set) var versions: [VersionInfo] = []
    var selected: String?
    private(set) var phase = Phase.choosing
    /// The chosen version's state, once built.
    @ObservationIgnored private(set) var target: EngineState?
    @ObservationIgnored let list: @MainActor () async throws -> [VersionInfo]
    @ObservationIgnored let state: @MainActor (UInt64) async throws -> EngineState
    @ObservationIgnored let current: @MainActor () -> EngineState
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>
    @ObservationIgnored var compare: @MainActor (CompareSheetModel) -> Void = { _ in }
    @ObservationIgnored var onClose: @MainActor () -> Void = {}

    init(documentTitle: String, list: @escaping @MainActor () async throws -> [VersionInfo], state: @escaping @MainActor (UInt64) async throws -> EngineState,
         current: @escaping @MainActor () -> EngineState, perform: @escaping @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>) {
        self.documentTitle = documentTitle
        self.list = list
        self.state = state
        self.current = current
        self.perform = perform
    }

    var version: VersionInfo? { versions.first { $0.id == selected } }

    /// Lists the versions.
    func load() async {
        do {
            versions = try await list().sorted { $0.serverSeq > $1.serverSeq }
            selected = selected ?? versions.first?.id
            phase = .choosing
        } catch {
            phase = .failed("Versions could not be listed: \(error.localizedDescription)")
        }
    }

    /// btn:[Restore…]: builds the version's state and the confirmation's counts.
    func prepare() async {
        guard let version else { return }
        phase = .loading
        do {
            let target = try await state(version.serverSeq)
            self.target = target
            let current = current()
            let summary = await Task.detached(priority: .userInitiated) { RestoreCommand.summary(target: target, current: current) }.value
            phase = .confirming(summary)
        } catch {
            phase = .failed("The version could not be read: \(error.localizedDescription)")
        }
    }

    /// The confirmation's sentence.
    var confirmation: String? {
        guard case .confirming(let summary) = phase, let version else { return nil }
        return summary.isEmpty ? "The document already matches “\(version.name)”." : "Restore “\(version.name)”? \(summary.sentence)"
    }

    /// btn:[Restore]: the restore, one change computed against the state it is performed on.
    @discardableResult
    func restore() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard case .confirming(let summary) = phase, !summary.isEmpty, let target, let version else { return nil }
        let task = perform(RestoreCommand(target: target, name: version.name))
        onClose()
        return task
    }

    /// btn:[Compare]: the version against the document now, read-only.
    @discardableResult
    func showCompare() async -> CompareSheetModel? {
        guard let version else { return nil }
        if target == nil { target = try? await state(version.serverSeq) }
        guard let target else { return nil }
        let model = CompareSheetModel(comparison: DocumentComparison(a: target, b: current()), titleA: "Older", titleB: "Now",
                                      heading: "Compare “\(version.name)” with now")
        compare(model)
        return model
    }

    func back() {
        phase = .choosing
    }

    func cancel() { onClose() }
}

struct RestoreVersionSheet: View {
    let model: RestoreVersionModel

    static func prepare(_ model: RestoreVersionModel) -> () -> Void { { Task { await model.prepare() } } }
    static func restore(_ model: RestoreVersionModel) -> () -> Void { { model.restore() } }
    static func compare(_ model: RestoreVersionModel) -> () -> Void { { Task { await model.showCompare() } } }
    static func back(_ model: RestoreVersionModel) -> () -> Void { { model.back() } }
    static func cancel(_ model: RestoreVersionModel) -> () -> Void { { model.cancel() } }
    static func selection(_ model: RestoreVersionModel) -> Binding<String?> {
        Binding(get: { model.selected }, set: { model.selected = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Restore a Version of “\(model.documentTitle)”").font(.headline)
            switch model.phase {
            case .choosing, .loading:
                if model.versions.isEmpty {
                    Text("This document has no named versions yet.").foregroundStyle(.secondary)
                } else {
                    List(model.versions, selection: Self.selection(model)) { version in
                        VStack(alignment: .leading) {
                            Text(version.name)
                            Text(version.createdAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Version \(version.serverSeq)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(version.id as String?)
                    }
                    .frame(minHeight: 160)
                }
                if model.phase == .loading { ProgressView().controlSize(.small) }
            case .confirming:
                Text(model.confirmation ?? "").fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("restore.confirmation")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", action: Self.cancel(model)).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Compare", action: Self.compare(model)).disabled(model.version == nil)
                if case .confirming = model.phase {
                    Button("Back", action: Self.back(model))
                    Button("Restore", action: Self.restore(model)).keyboardShortcut(.defaultAction).accessibilityIdentifier("restore.confirm")
                } else {
                    Button("Restore…", action: Self.prepare(model)).disabled(model.version == nil || model.phase == .loading)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
