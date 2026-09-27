import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTRender

/// The Inspect panel (inspect.adoc, "The Inspect panel", "Copying as code", "Copying as PNG";
/// COLLAB-037's snippet half over COLLAB-036's library): menu:Window[Inspect] reads the front
/// window's selection -- one object, or several as one group -- and shows its *Layout* (position of
/// the top-left corner on its page and size), the *Code* tabs (SVG, CSS, Swift from WTInterchange's
/// snippets, each with btn:[Copy]) and btn:[PNG 1×] / btn:[PNG 2×] / btn:[PNG 3×], with the
/// *Notation*, *Unit* and *Scale* pop-ups every value follows -- *Unit* and *Scale* are the
/// *Inspect unit* and *Inspect scale* preferences once `attach(preferences:)` ran.  A row whose value
/// a collaborator's change altered flashes in their colour (the attribution pulse of the object,
/// with the row as a second target), and `remote` points the panel at a collaborator's selection
/// (COLLAB-037's rest).
@MainActor
@Observable
final class InspectPanelModel {
    enum Tab: String, CaseIterable, Identifiable {
        case svg = "SVG"
        case css = "CSS"
        case swift = "Swift"
        var id: String { rawValue }
    }

    static let scales: [Double] = [1, 2, 3]
    /// The *Unit* choices: the document's own unit, then the fixed ones (`SnippetUnit` raw values).
    static let unitChoices: [(String, String)] = [(documentUnit, "Document units")] + units.map { ($0.0.rawValue, $0.1) }
    static let documentUnit = "document"
    static let notations: [(SnippetNotation, String)] = [(.hex, "Hex"), (.rgb, "rgb()"), (.displayP3, "Display P3"), (.oklch, "OKLCH"), (.cmyk, "CMYK")]
    static let units: [(SnippetUnit, String)] = [(.points, "Points"), (.pixels, "Pixels"), (.millimeters, "Millimeters"), (.centimeters, "Centimeters"),
                                                  (.inches, "Inches")]

    @ObservationIgnored var window: @MainActor () -> DocumentWindowController? = { nil }
    /// A blob's bytes by SHA-256 when it is on this Mac (the placed images a snippet draws).
    @ObservationIgnored var blob: (Data) -> Data? = { _ in nil }
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    /// Where the unit and scale are remembered on this Mac (`inspect.unit`, `inspect.scale`).
    @ObservationIgnored let defaults: UserDefaults?
    /// Chooses where *Option*-click on a PNG button saves; nil when cancelled.
    @ObservationIgnored var chooseDestination: @MainActor (String) -> URL? = InspectPanelModel.savePanel
    /// Whether kbd:[Option] is held (a PNG button saves instead of copying).
    @ObservationIgnored var optionDown: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.option) }
    var notation: SnippetNotation = .hex
    /// The *Unit* pop-up: a `SnippetUnit` raw value or `documentUnit`.  Remembered in `defaults`
    /// until `attach(preferences:)` hands it to the *Inspect unit* preference.
    var unitChoice: String = SnippetUnit.pixels.rawValue {
        didSet {
            guard unitChoice != oldValue else { return }
            if let preferences { preferences.set(unitChoice, for: PreferenceCatalog.Sync.inspectUnit) } else { defaults?.set(unitChoice, forKey: Self.unitKey) }
        }
    }
    var scale: Double = 1 {
        didSet {
            guard scale != oldValue else { return }
            if let preferences { preferences.set(scale, for: PreferenceCatalog.Sync.inspectScale) } else { defaults?.set(scale, forKey: Self.scaleKey) }
        }
    }

    /// A custom factor typed in the scale field, kept between 0.1× and 16×.
    func setCustomScale(_ value: Double) {
        scale = value.isFinite ? min(max(value, 0.1), 16) : 1
    }
    /// A scale as the pop-up shows it ("1.5×").
    static func scaleTitle(_ scale: Double) -> String {
        (scale.rounded() == scale ? "\(Int(scale))" : String(format: "%g", scale)) + "×"
    }

    static let unitKey = "inspect.unit"
    static let scaleKey = "inspect.scale"
    var tab: Tab = .svg
    private(set) var revision = 0
    /// What the last copy put on the pasteboard ("Copied CSS").
    private(set) var copied: String?
    /// Rows flashing after a collaborator's change, by row label ("Width", "Code").
    private(set) var flashing: [String: RowFlash] = [:]
    /// Whose selection the panel reads instead of the window's.
    let remote = RemoteSelectionInspection()
    @ObservationIgnored private(set) var preferences: PreferenceStore?
    @ObservationIgnored private var preferenceToken: UUID?
    /// The rows last shown and whose they were, to see which a change altered.
    @ObservationIgnored private var shownRows: [String: String] = [:]
    @ObservationIgnored private var shownNodes: [SelectionID] = []
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    /// How long the flashed rows stay marked; zero clears them on the next read.
    @ObservationIgnored var flashClearDelay: Duration = .milliseconds(1500)
    @ObservationIgnored private var clearing: Task<Void, Never>?

    /// One flashing row: the author's presence colour and when the flash began.
    struct RowFlash: Equatable {
        var colorIndex: Int
        var started: Date
        var color: SwiftUI.Color {
            let color = PresencePalette.color(at: colorIndex)
            return SwiftUI.Color(red: color.red, green: color.green, blue: color.blue)
        }
    }

    /// `defaults` remembers the unit and scale (COLLAB-037's rest) until `attach(preferences:)` hands
    /// them to the preferences; nil keeps them for the panel's life only.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let raw = defaults?.string(forKey: Self.unitKey), raw == Self.documentUnit || SnippetUnit(rawValue: raw) != nil { unitChoice = raw }
        if let stored = defaults?.object(forKey: Self.scaleKey) as? Double, stored > 0 { scale = stored }
    }

    /// The unit every value reads in: the chosen one, or the document's (picas and kyus read as
    /// points and millimetres, a custom unit as points).
    var unit: SnippetUnit {
        get {
            if let fixed = SnippetUnit(rawValue: unitChoice) { return fixed }
            return window().map { Self.snippetUnit(for: $0.documentHandle.units) } ?? .points
        }
        set { unitChoice = newValue.rawValue }
    }

    static func snippetUnit(for unit: LengthUnit) -> SnippetUnit {
        switch unit {
        case .pixels: .pixels
        case .inches, .decimalInches: .inches
        case .millimeters, .kyus: .millimeters
        case .centimeters: .centimeters
        default: .points
        }
    }

    /// The *Scale* pop-up's entries: 1×, 2×, 3× and a custom factor set in Preferences.
    var scaleChoices: [Double] { Self.scales.contains(scale) ? Self.scales : Self.scales + [scale] }

    /// Backs *Unit* and *Scale* with the *Inspect unit* and *Inspect scale* preferences (local to
    /// this Mac; the Preferences window's rows), following changes made there.  From then on the
    /// preferences, not `defaults`, remember them.
    func attach(preferences: PreferenceStore) {
        if let preferenceToken { self.preferences?.stopObserving(preferenceToken) }
        self.preferences = nil
        unitChoice = preferences[PreferenceCatalog.Sync.inspectUnit]
        scale = preferences[PreferenceCatalog.Sync.inspectScale]
        self.preferences = preferences
        preferenceToken = preferences.observe { [weak self] change in
            guard let self, let preferences = self.preferences else { return }
            if change.id == PreferenceCatalog.Sync.inspectUnit.id {
                let value = preferences[PreferenceCatalog.Sync.inspectUnit]
                if value != self.unitChoice { self.unitChoice = value }
            } else if change.id == PreferenceCatalog.Sync.inspectScale.id {
                let value = preferences[PreferenceCatalog.Sync.inspectScale]
                if value != self.scale { self.scale = value }
            }
        }
    }

    /// The selection or the document changed: the panel reads again.
    func touch() {
        revision += 1
        copied = nil
    }

    /// The window's selection changed: the panel reads it (a collaborator's selection being
    /// inspected gives way to it) without flashing.
    func selectionDidChange() {
        remote.stop()
        touch()
        rememberRows()
    }

    /// The document changed: the panel reads again, and once the change has been applied
    /// everywhere (the attribution pulses included) the rows it altered flash.
    func documentDidChange() {
        touch()
        Task { @MainActor [weak self] in self?.rowsMayHaveChanged() }
    }

    /// Presence changed: a collaborator's selection being inspected is followed, or given up when
    /// they left.
    func presenceDidChange() {
        guard remote.isActive, let window = window() else { return }
        remote.presenceDidChange(window.presence.participants)
        touch()
        rememberRows()
    }

    /// Inspects `participant`'s selection in `window` (the name tag or the command).
    func inspect(_ participant: RemoteParticipant) {
        remote.start(participant)
        touch()
        rememberRows()
    }

    /// Back to the window's own selection.
    func stopInspectingRemote() {
        guard remote.stop() else { return }
        touch()
        rememberRows()
    }

    /// The ids the panel reads: the inspected collaborator's selection, else the window's.
    var inspectedIDs: [SelectionID] {
        _ = revision
        guard let window = window() else { return [] }
        if remote.isActive { return remote.participant(in: window.presence.participants)?.selection ?? [] }
        return window.selection.selection.ids
    }

    /// A collaborator's selection names objects this Mac has not received yet (*Waiting for object…*).
    var isWaitingForRemote: Bool {
        guard remote.isActive, let window = window() else { return false }
        let ids = inspectedIDs
        return !ids.isEmpty && !ids.contains { window.documentHandle.state.isLive($0.opID) }
    }

    /// The rows compared for the flash: the layout values and the current Code tab.
    func rowValues(_ object: SnippetObject) -> [String: String] {
        var rows = Dictionary(uniqueKeysWithValues: layout(object).map { ($0.label, $0.value) })
        rows["Code"] = code(tab, for: object)
        return rows
    }

    private func rememberRows() {
        shownNodes = inspectedIDs
        shownRows = object.map(rowValues) ?? [:]
    }

    /// Compares the rows with the ones last shown: those a change by a collaborator altered on
    /// the same objects flash in that collaborator's colour.
    func rowsMayHaveChanged() {
        let nodes = inspectedIDs
        let rows = object.map(rowValues) ?? [:]
        defer {
            shownNodes = nodes
            shownRows = rows
        }
        guard nodes == shownNodes, let window = window() else { return }
        let changed = rows.filter { row in shownRows[row.key].map { $0 != row.value } ?? false }.map(\.key).sorted()
        guard !changed.isEmpty else { return }
        let wanted = Set(nodes)
        guard let pulse = window.collaboration.flashes.active().first(where: { wanted.contains($0.node) }) else { return }
        let at = now()
        for row in changed { flashing[row] = RowFlash(colorIndex: pulse.colorIndex, started: at) }
        scheduleClear()
    }

    /// The flash on `row`, nil when it is not flashing.
    func flash(_ row: String) -> RowFlash? {
        guard let flash = flashing[row], now().timeIntervalSince(flash.started) < AttributionFlashController.duration else { return nil }
        return flash
    }

    private func scheduleClear() {
        clearing?.cancel()
        let delay = flashClearDelay
        clearing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let at = self.now()
            self.flashing = self.flashing.filter { at.timeIntervalSince($0.value.started) < AttributionFlashController.duration }
        }
    }

    var options: SnippetOptions { SnippetOptions(notation: notation, unit: unit, scale: scale) }

    /// The selection as a snippet object: the one selected object, or every selected object as
    /// one group (drawn as the SVG and PNG snippets; the CSS and Swift ones say what they cannot
    /// express).  Nil with nothing selected.
    var object: SnippetObject? {
        _ = revision
        guard let window = window() else { return nil }
        let document = window.documentHandle
        let nodes = inspectedIDs.map(\.opID)
        let objects = nodes.compactMap { ExportSnapshot.snippetObject($0, scene: document.scene, state: document.state, blob: blob) }
        guard let first = objects.first else { return nil }
        guard objects.count > 1 else { return first }
        var assets: [String: ExportAsset] = [:]
        for object in objects {
            for (id, asset) in object.assets where assets[id] == nil { assets[id] = asset }
        }
        return SnippetObject(name: "selection", shape: .other, item: .group(GroupItem(children: objects.map(\.item))), assets: assets,
                             swatchNames: first.swatchNames)
    }

    /// *Colors*, *Stroke*, *Fills*, *Effects*, *Typography* and *Text* (COLLAB-037's rest), in the
    /// notation, unit and scale.
    func readout(_ object: SnippetObject) -> SnippetReadout {
        SnippetReadout(object, options: options)
    }

    /// *Layout*: the top-left corner on the object's page and the size, in the unit.
    func layout(_ object: SnippetObject) -> [(label: String, value: String)] {
        let bounds = object.bounds
        let page = window()?.documentHandle.pageList.page(containing: bounds.center)?.rect ?? Rect(x: 0, y: 0, width: 0, height: 0)
        let origin = Point(x: page.minX, y: page.minY)
        return [
            ("X", unit.format(bounds.minX - origin.x, scale: scale)), ("Y", unit.format(bounds.minY - origin.y, scale: scale)),
            ("Width", unit.format(bounds.width, scale: scale)), ("Height", unit.format(bounds.height, scale: scale)),
        ]
    }

    /// The snippet of `tab`.
    func code(_ tab: Tab, for object: SnippetObject) -> String {
        switch tab {
        case .svg: SVGSnippet.make(object)
        case .css: CSSSnippet.make(object, options: options)
        case .swift: SwiftSnippet.make(object, options: options).text
        }
    }

    /// btn:[Copy] in a Code tab (and a click on a Layout value): the text on the pasteboard.
    @discardableResult
    func copy(_ text: String, what: String) -> Bool {
        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        copied = "Copied \(what)"
        return wrote
    }

    @discardableResult
    func copyCode(_ tab: Tab) -> Bool {
        guard let object else { return false }
        return copy(code(tab, for: object), what: tab.rawValue)
    }

    /// A PNG button: kbd:[Option]-click saves the PNG to a file, a click copies it.
    @discardableResult
    func png(scale: Double) -> Data? {
        optionDown() ? savePNG(scale: scale) : copyPNG(scale: scale)
    }

    /// kbd:[Option]-click on btn:[PNG 1×] … btn:[PNG 3×]: the PNG written to a chosen file.
    @discardableResult
    func savePNG(scale: Double) -> Data? {
        guard let object, let url = chooseDestination(PNGSnippet.fileName(object, scale: scale)) else { return nil }
        let data = PNGSnippet.make(object, scale: scale)
        do {
            try data.write(to: url, options: .atomic)
            copied = "Saved \(url.lastPathComponent)"
            return data
        } catch {
            copied = "The PNG could not be saved"
            return nil
        }
    }

    static func savePanel(_ name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.png]
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// btn:[PNG 1×] … btn:[PNG 3×]: the selection as a PNG at `scale` on the pasteboard.
    @discardableResult
    func copyPNG(scale: Double) -> Data? {
        guard let object else { return nil }
        let data = PNGSnippet.make(object, scale: scale)
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        copied = "Copied \(PNGSnippet.fileName(object, scale: scale))"
        return data
    }
}

enum InspectPanel {
    static let id: PanelID = "inspect"
    static let group = "Inspect"

    static func descriptor(model: InspectPanelModel) -> PanelDescriptor {
        PanelDescriptor(id: id, title: "Inspect", icon: "ruler", defaultGroup: group, menuOrder: 74, helpSlug: "inspect") {
            InspectPanelBody(model: model)
        }
    }
}

struct InspectPanelBody: View {
    @Bindable var model: InspectPanelModel

    static func copying(_ model: InspectPanelModel, _ text: String, _ what: String) -> () -> Void { { model.copy(text, what: what) } }
    static func copyingCode(_ model: InspectPanelModel, _ tab: InspectPanelModel.Tab) -> () -> Void { { model.copyCode(tab) } }
    static func copyingPNG(_ model: InspectPanelModel, _ scale: Double) -> () -> Void { { model.png(scale: scale) } }
    static func customScale(_ model: InspectPanelModel) -> Binding<Double> {
        Binding(get: { model.scale }, set: { model.setCustomScale($0) })
    }

    /// A section of labelled values, each copied by a click.
    @ViewBuilder
    static func rows(_ title: String, _ rows: [SnippetReadout.Row], model: InspectPanelModel) -> some View {
        if !rows.isEmpty {
            Text(title).font(.headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Button(action: copying(model, row.value.isEmpty ? row.label : row.value, row.label)) {
                    HStack(alignment: .top) {
                        Text(row.label).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.value).multilineTextAlignment(.trailing).monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inspect.\(title.lowercased()).\(row.label)")
            }
        }
    }

    /// A row's background: the flashing author's colour, else nothing.
    static func flashBackground(_ model: InspectPanelModel, _ row: String) -> SwiftUI.Color {
        model.flash(row)?.color.opacity(0.35) ?? .clear
    }

    static func stopRemote(_ model: InspectPanelModel) -> () -> Void { { model.stopInspectingRemote() } }

    @ViewBuilder var remoteHeader: some View {
        if model.remote.isActive {
            HStack {
                Circle().fill(InspectPanelModel.RowFlash(colorIndex: model.remote.colorIndex, started: .distantPast).color).frame(width: 8, height: 8)
                Text(model.remote.title).font(.callout.weight(.medium))
                Spacer()
                Button("Stop", action: Self.stopRemote(model)).controlSize(.small)
            }
            .accessibilityIdentifier("inspect.remote")
        }
    }

    var body: some View {
        if let object = model.object {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    remoteHeader
                    HStack {
                        Picker("Notation", selection: $model.notation) {
                            ForEach(InspectPanelModel.notations, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .accessibilityIdentifier("inspect.notation")
                        Picker("Unit", selection: $model.unitChoice) {
                            ForEach(InspectPanelModel.unitChoices, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .accessibilityIdentifier("inspect.unit")
                        Picker("Scale", selection: $model.scale) {
                            ForEach(model.scaleChoices, id: \.self) { Text(InspectPanelModel.scaleTitle($0)).tag($0) }
                        }
                        .accessibilityIdentifier("inspect.scale")
                        // A custom factor (inspect.adoc, "Units and scale").
                        TextField("Custom", value: Self.customScale(model), format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 48)
                            .accessibilityIdentifier("inspect.customScale")
                    }
                    .labelsHidden()
                    Text("Layout").font(.headline)
                    ForEach(model.layout(object), id: \.label) { row in
                        Button(action: Self.copying(model, row.value, row.label)) {
                            HStack {
                                Text(row.label).foregroundStyle(.secondary)
                                Spacer()
                                Text(row.value).monospacedDigit()
                            }
                            .background(Self.flashBackground(model, row.label))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("inspect.layout.\(row.label)")
                    }
                    let readout = model.readout(object)
                    if !readout.colors.isEmpty {
                        Text("Colors").font(.headline)
                        ForEach(Array(readout.colors.enumerated()), id: \.offset) { _, row in
                            Button(action: Self.copying(model, row.value, row.name ?? "color")) {
                                HStack {
                                    SwiftUI.Circle().fill(SwiftUI.Color(cgColor: row.color.cgColor)).frame(width: 12, height: 12)
                                    Text(row.name ?? "").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(row.value).monospacedDigit()
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("inspect.color.\(row.value)")
                        }
                    }
                    Self.rows("Stroke", readout.stroke, model: model)
                    Self.rows("Fills", readout.fills, model: model)
                    Self.rows("Effects", readout.effects, model: model)
                    ForEach(Array(readout.typography.enumerated()), id: \.offset) { index, run in
                        Self.rows(readout.typography.count > 1 ? "Typography \(index + 1)" : "Typography", run, model: model)
                    }
                    if let text = readout.text {
                        Text("Text").font(.headline)
                        Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("inspect.text")
                        Button("Copy Text", action: Self.copying(model, text, "text")).accessibilityIdentifier("inspect.copyText")
                    }
                    Text("Code").font(.headline)
                    Picker("Code", selection: $model.tab) {
                        ForEach(InspectPanelModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("inspect.tab")
                    Text(model.code(model.tab, for: object))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Self.flashBackground(model, "Code"))
                        .accessibilityIdentifier("inspect.code")
                    Button("Copy", action: Self.copyingCode(model, model.tab)).accessibilityIdentifier("inspect.copy")
                    Text("Export").font(.headline)
                    HStack {
                        ForEach(InspectPanelModel.scales, id: \.self) { scale in
                            Button("PNG \(Int(scale))×", action: Self.copyingPNG(model, scale)).accessibilityIdentifier("inspect.png.\(Int(scale))")
                        }
                    }
                    if let copied = model.copied {
                        Text(copied).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("inspect.copied")
                    }
                }
                .padding()
            }
        } else if model.isWaitingForRemote {
            VStack(alignment: .leading, spacing: 10) {
                remoteHeader
                Text("Waiting for object…").font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("inspect.waiting")
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text(model.remote.isActive ? "\(model.remote.name) has nothing selected." : "Select an object to inspect it.")
                .font(.callout).foregroundStyle(.secondary).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("inspect.empty")
        }
    }
}
