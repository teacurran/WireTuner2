import AppKit
import GRPCCore
import GRPCProtobuf
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTSync

/// What `BranchService.MergeBranch` answered.
struct MergeResult: Equatable, Sendable {
    var firstParentSeq: UInt64
    var lastParentSeq: UInt64
    /// Ops the replay dropped (they no longer applied).
    var droppedOps: Int
}

/// Why a merge was refused.
enum MergeFailure: Error, Equatable {
    /// `MERGE_STALE`: the parent moved on past the reviewed seq; review again.
    case stale
}

/// `BranchService.MergeBranch` (branches.adoc, "Merging a branch"; COLLAB-018).
protocol BranchMerging: Sendable {
    func merge(branch: String, reviewedParentSeq: UInt64, excluded: [OpID], keepOpen: Bool) async throws -> MergeResult
}

struct GRPCBranchMerging: BranchMerging {
    typealias Methods = Wiretuner_Docs_V1_BranchService.Method

    let caller: any UnaryCaller
    let accessToken: @Sendable () async throws -> String

    /// `MERGE_STALE` from an `RPCError`'s `ErrorInfo`; any other error as it is.
    static func mapped(_ error: any Error) -> any Error {
        guard let rpc = error as? RPCError else { return error }
        let details = (try? rpc.unpackGoogleRPCStatus())?.details ?? []
        let reason = details.lazy.compactMap(\.errorInfo).first.flatMap { SyncCallError.reason(named: $0.reason) }
        return reason == .mergeStale ? MergeFailure.stale : error
    }

    func merge(branch: String, reviewedParentSeq: UInt64, excluded: [OpID], keepOpen: Bool) async throws -> MergeResult {
        var request = Wiretuner_Docs_V1_MergeBranchRequest()
        request.branchDocumentID = branch
        request.reviewedParentSeq = reviewedParentSeq
        request.excludedNodes = excluded.map(\.proto)
        request.keepOpen = keepOpen
        do {
            let response: Methods.MergeBranch.Output = try await caller.unary(Methods.MergeBranch.descriptor, request, accessToken: try await accessToken())
            return MergeResult(firstParentSeq: response.firstParentSeq, lastParentSeq: response.lastParentSeq, droppedOps: Int(response.droppedOps))
        } catch {
            throw Self.mapped(error)
        }
    }
}

/// The merge flow (branches.adoc, "Merging a branch"; COLLAB-018): from a branch window,
/// menu:File[Branch > Merge…] reviews every object that differs between the branch and main as
/// this Mac holds them -- per object *Use branch* (the default: the branch's changes are replayed
/// onto main) or *Use main* (the object is excluded, so main keeps its registers byte for byte) --
/// with *Keep branch open*, then asks the server to merge.  A main that moved on meanwhile
/// (`MERGE_STALE`) reopens the review over the new state; the result names the changes merged and
/// any the replay dropped.
@MainActor
@Observable
final class BranchMergeModel {
    enum Choice: String, CaseIterable { case branch, main }

    enum Phase: Equatable {
        case reviewing
        case merging
        case merged(MergeResult)
        case failed(String)
    }

    let branchID: String
    let branchName: String
    private(set) var comparison: DocumentComparison
    private(set) var reviewedParentSeq: UInt64
    private(set) var choices: [OpID: Choice] = [:]
    var keepOpen = false
    private(set) var phase = Phase.reviewing
    private(set) var reopened = 0
    @ObservationIgnored let merging: any BranchMerging
    /// The branch's state and main's state and seq as this Mac holds them now.
    @ObservationIgnored let states: @MainActor () async -> (branch: EngineState, main: EngineState, mainSeq: UInt64)?
    @ObservationIgnored var onClose: @MainActor () -> Void = {}
    @ObservationIgnored var onMerged: @MainActor (MergeResult) -> Void = { _ in }

    init(branchID: String, branchName: String, branch: EngineState, main: EngineState, mainSeq: UInt64, merging: any BranchMerging,
         states: @escaping @MainActor () async -> (branch: EngineState, main: EngineState, mainSeq: UInt64)?) {
        self.branchID = branchID
        self.branchName = branchName
        comparison = DocumentComparison(a: branch, b: main)
        reviewedParentSeq = mainSeq
        self.merging = merging
        self.states = states
    }

    var entries: [DocumentComparison.Entry] { comparison.entries }

    func choice(_ node: OpID) -> Choice { choices[node] ?? .branch }

    func choose(_ choice: Choice, for node: OpID) { choices[node] = choice }

    /// The objects left out of the merge (*Use main*).
    var excluded: [OpID] { entries.map(\.node).filter { choice($0) == .main } }

    /// The row's name: the object's name in whichever state has it.
    func name(_ entry: DocumentComparison.Entry) -> String {
        let state = comparison.a.isLive(entry.node) ? comparison.a : comparison.b
        return state.displayName(of: entry.node)
    }

    static func kindTitle(_ kind: DocumentComparison.Kind) -> String {
        switch kind {
        case .changed: "Changed on the branch"
        case .onlyA: "Added on the branch"
        case .onlyB: "Only on main"
        }
    }

    /// btn:[Merge].
    @discardableResult
    func merge() async -> MergeResult? {
        phase = .merging
        do {
            let result = try await merging.merge(branch: branchID, reviewedParentSeq: reviewedParentSeq, excluded: excluded, keepOpen: keepOpen)
            phase = .merged(result)
            onMerged(result)
            return result
        } catch MergeFailure.stale {
            await reopen()
            return nil
        } catch {
            phase = .failed("The branch could not be merged: \(error.localizedDescription)")
            return nil
        }
    }

    /// Main moved on: the review is built again over the states now, keeping the choices made.
    func reopen() async {
        guard let states = await states() else {
            phase = .failed("Main is not on this Mac")
            return
        }
        comparison = DocumentComparison(a: states.branch, b: states.main)
        reviewedParentSeq = states.mainSeq
        reopened += 1
        phase = .reviewing
    }

    /// The result's sentence: "Merged 12 changes into main." (and the dropped ones).
    static func summary(_ result: MergeResult) -> String {
        let count = result.lastParentSeq >= result.firstParentSeq && result.lastParentSeq > 0 ? Int(result.lastParentSeq - result.firstParentSeq + 1) : 0
        let merged = "Merged \(count) \(count == 1 ? "change" : "changes") into main."
        return result.droppedOps == 0 ? merged : merged + " \(result.droppedOps) no longer applied and were left out."
    }
}

struct BranchMergeSheet: View {
    let model: BranchMergeModel

    static func merging(_ model: BranchMergeModel) -> () -> Void { { Task { await model.merge() } } }
    static func choice(_ model: BranchMergeModel, _ node: OpID) -> Binding<BranchMergeModel.Choice> {
        Binding(get: { model.choice(node) }, set: { model.choose($0, for: node) })
    }
    static func keepOpen(_ model: BranchMergeModel) -> Binding<Bool> { Binding(get: { model.keepOpen }, set: { model.keepOpen = $0 }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge \u{201C}\(model.branchName)\u{201D} into main").font(.headline)
            if model.reopened > 0 {
                Text("Main changed while you were reviewing; the list shows it as it is now.").font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("merge.reopened")
            }
            List(model.entries) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(model.name(entry))
                        Text(BranchMergeModel.kindTitle(entry.kind)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Self.choice(model, entry.node)) {
                        Text("Use branch").tag(BranchMergeModel.Choice.branch)
                        Text("Use main").tag(BranchMergeModel.Choice.main)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
            }
            .frame(minHeight: 160)
            .accessibilityIdentifier("merge.list")
            Toggle("Keep branch open", isOn: Self.keepOpen(model)).accessibilityIdentifier("merge.keepOpen")
            switch model.phase {
            case .merged(let result):
                Text(BranchMergeModel.summary(result)).accessibilityIdentifier("merge.result")
            case .failed(let message):
                Text(message).foregroundStyle(.red).accessibilityIdentifier("merge.message")
            default:
                EmptyView()
            }
            HStack {
                Spacer()
                Button(model.phase.isDone ? "Done" : "Cancel", action: model.onClose).keyboardShortcut(.cancelAction).accessibilityIdentifier("merge.cancel")
                Button("Merge", action: Self.merging(model)).keyboardShortcut(.defaultAction).disabled(model.phase != .reviewing).accessibilityIdentifier("merge.merge")
            }
        }
        .padding(16)
        .frame(width: 480, height: 420)
    }
}

extension BranchMergeModel.Phase {
    var isDone: Bool {
        if case .merged = self { return true }
        return false
    }
}

/// menu:File[Branch > Merge…] in place of its placeholder.
@MainActor
enum BranchMergeCommand {
    static let notBranch = "Open a branch to merge it into main"
    static let offline = "Merging needs the network"
    /// Main's last server seq on this Mac (what the review reviewed).
    static var parentSeq: @MainActor (String) async -> UInt64 = { _ in 0 }

    static func command(features: CollaborationFeatures, merging: @escaping @MainActor () -> (any BranchMerging)?,
                        window: @escaping @MainActor () -> DocumentWindowController?) -> Command {
        Command(id: CollaborationFeatures.ID.mergeBranch, title: "Merge…", menu: MenuPath(StandardCommands.Menu.file, "Branch", section: 1, subsection: 1),
                keywords: ["branch", "merge"],
                validation: {
                    guard let window = window(), features.attach(window).branches.isBranch else { return .disabled(notBranch) }
                    return merging() == nil ? .disabled(offline) : .enabled
                },
                action: .perform { _ = present(features: features, merging: merging, window: window) })
    }

    /// The review sheet over the front branch window; nil when it is not a branch or main is not here.
    @discardableResult
    static func present(features: CollaborationFeatures, merging: @escaping @MainActor () -> (any BranchMerging)?,
                        window: @escaping @MainActor () -> DocumentWindowController?) -> Task<BranchMergeModel?, Never> {
        Task { @MainActor in
            guard let window = window(), let client = merging() else { return nil }
            let branches = features.attach(window).branches
            guard let current = branches.current else { return nil }
            let parentID = branches.parentID
            let states: @MainActor () async -> (branch: EngineState, main: EngineState, mainSeq: UInt64)? = { [weak window] in
                guard let window, let main = await features.state(parentID) else { return nil }
                return (window.documentHandle.state, main, await parentSeq(parentID))
            }
            guard let initial = await states() else {
                window.statusBar.show(message: "Main is not on this Mac yet")
                return nil
            }
            let model = BranchMergeModel(branchID: current.id, branchName: current.name, branch: initial.branch, main: initial.main, mainSeq: initial.mainSeq,
                                         merging: client, states: states)
            model.onClose = { features.dismiss("merge-sheet") }
            model.onMerged = { [weak window] result in window?.statusBar.show(message: BranchMergeModel.summary(result)) }
            features.present(BranchMergeSheet(model: model), identifier: "merge-sheet", on: window)
            return model
        }
    }
}
