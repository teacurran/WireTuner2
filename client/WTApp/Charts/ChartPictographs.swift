import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// menu:Extensions[Chart > Pictograph…] and *Remove Pictograph* (charts.adoc, "Pictographs";
/// DRAW-034), for the series of the picked column; menu:Modify[Ungroup] and menu:Edit[Select >
/// Superselect] learn charts.
@MainActor
enum ChartPictographs {
    static let pictographID = "pictograph"
    static let removeID = "removePictograph"
    static let noPick = "Pick a column with the Subselect tool"
    /// Tests keep the sheet from showing.
    static var showsSheet = true
    private(set) static var presented: NSWindow?
    /// The sheet's view as shown last (tests run its actions).
    private(set) static var presentedSheet: PictographSheet?

    /// The picked chart and the series the pictograph applies to.
    static func target(_ window: DocumentWindowController?) -> (chart: OpID, key: ChartElementKeyRef)? {
        guard let window, let (chart, keys) = ChartElementStyling.picks(window.documentHandle, selection: window.selection.selection.ids.map(\.opID)) else { return nil }
        return (chart, ChartElementKeyRef(series: keys[0].series))
    }

    /// The objects on `window`'s pasteboard (btn:[Paste In]).
    static func pasted(_ window: DocumentWindowController) -> ClipboardPayload? {
        SystemObjectPasteboard(EditFeatures.pasteboard(of: window)).read().flatMap { ClipboardPayload(decoding: $0) }
    }

    /// The artwork of the key's current pictograph, as a payload.
    static func current(_ chart: OpID, key: ChartElementKeyRef, state: EngineState) -> ClipboardPayload? {
        guard let source = RemoveChartPictograph.source(chart, key: key, in: state), state.isLive(source) else { return nil }
        return ClipboardPayload(nodes: state.liveChildren(source).map { NodeTree($0, state: state) })
    }

    /// The sheet's btn:[OK]: the artwork as the series' pictograph, one change.
    static func command(chart: OpID, key: ChartElementKeyRef, artwork: ClipboardPayload?, repeating: Bool) -> (any WTModel.Command)? {
        guard let artwork, !artwork.nodes.isEmpty else { return nil }
        return SetChartPictograph(chart, key: key, artwork: artwork.nodes, repeating: repeating)
    }

    @discardableResult
    static func present(on window: DocumentWindowController) -> NSWindow? {
        guard let (chart, key) = target(window) else { return nil }
        let state = window.documentHandle.state
        let repeating = ChartElementStyling.override(key, in: chart, state: state)?.repeating ?? false
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 220), styleMask: [.titled], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        sheet.identifier = NSUserInterfaceItemIdentifier("pictograph-sheet")
        let close: () -> Void = { [weak sheet, weak window] in
            guard let sheet else { return }
            if let host = window?.window, host.attachedSheet === sheet { host.endSheet(sheet) } else { sheet.orderOut(nil) }
        }
        let model = PictographModel(artwork: current(chart, key: key, state: state), repeating: repeating)
        model.pasteIn = { [weak window] in window.flatMap(pasted) }
        model.copyOut = { [weak window] payload in
            guard let window else { return }
            SystemObjectPasteboard(EditFeatures.pasteboard(of: window)).write(payload.encoded())
        }
        let view = PictographSheet(model: model, commit: { [weak window] in
            if let window, let command = command(chart: chart, key: key, artwork: model.artwork, repeating: model.repeating) { window.objectEditing.perform(command) }
            close()
        }, cancel: close)
        sheet.contentViewController = NSHostingController(rootView: view)
        presented = sheet
        presentedSheet = view
        if showsSheet, let host = window.window { host.beginSheet(sheet) }
        return sheet
    }

    /// *Remove Pictograph*: nil when the series has none.
    @discardableResult
    static func remove(on window: DocumentWindowController) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let (chart, key) = target(window), RemoveChartPictograph.source(chart, key: key, in: window.documentHandle.state) != nil else { return nil }
        return window.objectEditing.perform(RemoveChartPictograph(chart, key: key))
    }

    static func extensions(existing: ExtensionRegistry, window: @escaping @MainActor () -> DocumentWindowController?) -> [ExtensionDescriptor] {
        let operations: [(String, @MainActor (DocumentWindowController) -> Void)] = [
            (pictographID, { present(on: $0) }),
            (removeID, { remove(on: $0) }),
        ]
        return operations.compactMap { id, run in
            guard var descriptor = existing.descriptor(for: id) else { return nil }
            descriptor.validate = { target(window()) == nil ? .disabled(noPick) : .enabled }
            descriptor.run = { _ in
                if let front = window() { run(front) }
                return nil
            }
            return descriptor
        }
    }

    // MARK: Ungroup and Superselect

    /// The selected charts, when every selected object is one.
    static func selectedCharts(_ window: DocumentWindowController?) -> [OpID]? {
        guard let window else { return nil }
        let state = window.documentHandle.state
        let nodes = window.selection.selection.ids.map(\.opID)
        guard !nodes.isEmpty, nodes.allSatisfy({ state.nodeKind($0) == .chart }) else { return nil }
        return nodes
    }

    /// menu:Modify[Ungroup] on charts: each baked into a group of paths, one change; the groups
    /// are selected.
    @discardableResult
    static func ungroup(_ window: DocumentWindowController) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let charts = selectedCharts(window) else { return nil }
        let commands: [any WTModel.Command] = charts.compactMap { chart in
            window.documentHandle.item(for: SelectionID(chart)).map { UngroupChart(chart, item: $0) }
        }
        guard !commands.isEmpty else { return nil }
        ChartElementPicks.of(window.documentHandle).clear()
        let parents = Set(charts.compactMap { Objects.parent(of: $0, in: window.documentHandle.state) })
        let task = window.objectEditing.perform(CommandBatch("Ungroup", commands))
        return Task { @MainActor in
            let change = await task.value
            // The new groups in the charts' places (not the groups inside them).
            let state = window.documentHandle.state
            let created = change?.createdObjects.filter { Objects.parent(of: $0, in: state).map(parents.contains) ?? false } ?? []
            window.selection.model.set(Selection(created.map { SelectionID($0) }))
            return change
        }
    }

    /// The Ungroup and Superselect commands with the chart cases in front of their own.
    static func commands(_ registry: CommandRegistry, window: @escaping @MainActor () -> DocumentWindowController?) -> [Command] {
        var result: [Command] = []
        if var command = registry[ContextMenuCatalog.ID.ungroup] {
            let action = command.action
            let validation = command.validation
            command.validation = { selectedCharts(window()) != nil ? .enabled : validation() }
            command.action = .perform {
                if let front = window(), ungroup(front) != nil { return }
                perform(action)
            }
            result.append(command)
        }
        if var superselect = registry[ContextMenuCatalog.ID.superselect] {
            let action = superselect.action
            superselect.action = .perform {
                if let front = window(), ChartElementStyling.picks(front.documentHandle, selection: front.selection.selection.ids.map(\.opID)) != nil,
                   ChartElementPicks.of(front.documentHandle).superselect() { return }
                perform(action)
            }
            result.append(superselect)
        }
        return result
    }

    /// Runs a command's own action.
    static func perform(_ action: CommandAction) {
        switch action {
        case .perform(let run): run()
        case .responder(let selector): NSApp.sendAction(NSSelectorFromString(selector), to: nil, from: nil)
        }
    }
}

/// The Pictograph sheet's state.
@MainActor
@Observable
final class PictographModel {
    var artwork: ClipboardPayload?
    var repeating: Bool
    @ObservationIgnored var pasteIn: @MainActor () -> ClipboardPayload? = { nil }
    @ObservationIgnored var copyOut: @MainActor (ClipboardPayload) -> Void = { _ in }

    init(artwork: ClipboardPayload?, repeating: Bool) {
        self.artwork = artwork
        self.repeating = repeating
    }

    /// What the preview says.
    var summary: String {
        guard let artwork, !artwork.nodes.isEmpty else { return "No artwork: copy some, then click Paste In." }
        return artwork.nodes.count == 1 ? "1 object" : "\(artwork.nodes.count) objects"
    }

    func paste() {
        if let pasted = pasteIn() { artwork = pasted }
    }

    func copy() {
        if let artwork { copyOut(artwork) }
    }
}

struct PictographSheet: View {
    @Bindable var model: PictographModel
    let commit: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pictograph").font(.headline)
            Text(model.summary).frame(maxWidth: .infinity, minHeight: 60).background(.quaternary).accessibilityIdentifier("pictograph.preview")
            HStack {
                Button("Paste In", action: model.paste).accessibilityIdentifier("pictograph.pasteIn")
                Button("Copy Out", action: model.copy).disabled(model.artwork == nil).accessibilityIdentifier("pictograph.copyOut")
            }
            Toggle("Repeating", isOn: $model.repeating).toggleStyle(.checkbox).accessibilityIdentifier("pictograph.repeating")
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: commit).keyboardShortcut(.defaultAction).disabled(model.artwork == nil).accessibilityIdentifier("pictograph.ok")
            }
        }
        .padding()
        .frame(width: 340)
    }
}
