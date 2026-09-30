import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

// The Glyph menu over the selection (glyph-grid.adoc, "Acting on several glyphs" and "Selecting
// glyphs"; glyph-editing.adoc, "Components" and "Anchors"; FONT-008, FONT-010, FONT-012, FONT-013
// rests): the Set Width / Side Bearing sheet, Center and Thirds in Width, Set Kind, Set Mark Color,
// Export Glyph, Build Accented Glyphs, Snap Components to Anchors, Decompose Components, the outline
// clean-ups, Round to Units, the Select submenu, and menu:View[Show Mark Attachment].  Every command
// acts on the targeted glyphs (a glyph tab's glyph, else the grid's selection) as one change.

extension TypefaceFeatures {
    enum GlyphMenuID {
        static let setWidth: CommandID = "glyph.setWidth"
        static let setLeft: CommandID = "glyph.setLeftSideBearing"
        static let setRight: CommandID = "glyph.setRightSideBearing"
        static let center: CommandID = "glyph.centerInWidth"
        static let thirds: CommandID = "glyph.thirdsInWidth"
        static let export: CommandID = "glyph.export"
        static let buildAccented: CommandID = "glyph.buildAccented"
        static let snapComponents: CommandID = "glyph.snapComponents"
        static let decompose: CommandID = "glyph.decompose"
        static let roundToUnits: CommandID = "glyph.roundToUnits"
        static let showMarkAttachment: CommandID = "view.showMarkAttachment"

        static func kind(_ kind: GlyphKind) -> CommandID { CommandID("glyph.kind.\(kind)") }
        static func markColor(_ color: Int) -> CommandID { CommandID("glyph.markColor.\(color)") }
        static func rewrite(_ operation: RewriteGlyphOutlines.Operation) -> CommandID { CommandID("glyph.\(operation)") }
        static func select(_ query: GlyphSelectionQuery) -> CommandID { CommandID("glyph.select.\(query)") }
    }

    /// The Set Kind submenu's titles.
    static func title(of kind: GlyphKind) -> String {
        switch kind {
        case .base: "Base"
        case .mark: "Mark"
        case .ligature: "Ligature"
        case .component: "Component"
        }
    }

    /// The Set Mark Color submenu's titles: None, then the grid's twelve colours.
    static let markColorTitles = ["None", "Red", "Orange", "Yellow", "Green", "Mint", "Teal", "Cyan", "Blue", "Indigo", "Purple", "Pink", "Brown"]

    func glyphMenuCommands() -> [Command] {
        let window = self.window
        let glyphMenu = Menu.glyph
        let needsGlyphs: @MainActor @Sendable () -> CommandValidation = { [unowned self] in
            guard let controller = window() else { return .disabled(Self.noDocument) }
            guard DocumentKind(controller.documentHandle.state) == .typeface else { return .disabled(Self.notTypeface) }
            return targetGlyphs(in: controller).isEmpty ? .disabled(Self.noGlyph) : .enabled
        }
        let needsTypeface: @MainActor @Sendable () -> CommandValidation = {
            guard let controller = window() else { return .disabled(Self.noDocument) }
            return DocumentKind(controller.documentHandle.state) == .typeface ? .enabled : .disabled(Self.notTypeface)
        }
        /// Enabled with a selection, checked when every targeted glyph passes `test`.
        func checked(_ test: @escaping @MainActor (Glyph) -> Bool) -> @MainActor @Sendable () -> CommandValidation {
            { [unowned self] in
                let validation = needsGlyphs()
                guard validation.isEnabled, let controller = window() else { return validation }
                let index = GlyphIndex(gridDocument(of: controller).state)
                let glyphs = targetGlyphs(in: controller).compactMap { index[$0] }
                let passing = glyphs.filter(test).count
                return CommandValidation(isChecked: passing == glyphs.count, isMixed: passing > 0 && passing < glyphs.count)
            }
        }
        func run(_ make: @escaping @MainActor ([OpID]) -> (any WTModel.Command)?) -> CommandAction {
            .perform { [unowned self] in performOnTargets(make) }
        }
        var commands: [Command] = [
            Command(id: GlyphMenuID.setWidth, title: "Set Advance Width…", menu: MenuPath(glyphMenu, section: 4), keywords: ["width", "spacing", "metrics"],
                    validation: needsGlyphs, action: .perform { [unowned self] in presentMetricSheet(.width) }),
            Command(id: GlyphMenuID.setLeft, title: "Set Left Side Bearing…", menu: MenuPath(glyphMenu, section: 4), keywords: ["lsb", "spacing"],
                    validation: needsGlyphs, action: .perform { [unowned self] in presentMetricSheet(.left) }),
            Command(id: GlyphMenuID.setRight, title: "Set Right Side Bearing…", menu: MenuPath(glyphMenu, section: 4), keywords: ["rsb", "spacing"],
                    validation: needsGlyphs, action: .perform { [unowned self] in presentMetricSheet(.right) }),
            Command(id: GlyphMenuID.center, title: "Center in Width", menu: MenuPath(glyphMenu, section: 4), keywords: ["center", "spacing"],
                    validation: needsGlyphs, action: run { SetGlyphBearings($0, .center) }),
            Command(id: GlyphMenuID.thirds, title: "Thirds in Width", menu: MenuPath(glyphMenu, section: 4), keywords: ["thirds", "spacing"],
                    validation: needsGlyphs, action: run { SetGlyphBearings($0, .thirds) }),
        ]
        for kind in GlyphKind.allCases {
            commands.append(Command(id: GlyphMenuID.kind(kind), title: Self.title(of: kind), menu: MenuPath(glyphMenu, "Set Kind", section: 5), keywords: ["kind", "mark"],
                                    validation: checked { $0.kind == kind }, action: run { SetGlyphAttributes($0, kind: kind) }))
        }
        for (color, title) in Self.markColorTitles.enumerated() {
            commands.append(Command(id: GlyphMenuID.markColor(color), title: title, menu: MenuPath(glyphMenu, "Set Mark Color", section: 5),
                                    keywords: ["color", "tag"], validation: checked { $0.markColor == color },
                                    action: run { SetGlyphAttributes($0, markColor: color) }))
        }
        commands.append(Command(id: GlyphMenuID.export, title: "Export Glyph", menu: MenuPath(glyphMenu, section: 5), keywords: ["export", "skip"],
                                validation: checked { !$0.skipExport }, action: .perform { [unowned self] in toggleExport() }))
        commands += [
            Command(id: GlyphMenuID.buildAccented, title: "Build Accented Glyphs", menu: MenuPath(glyphMenu, section: 6), keywords: ["accent", "component", "composite"],
                    validation: needsGlyphs, action: run { BuildAccentedGlyphs($0) }),
            Command(id: GlyphMenuID.snapComponents, title: "Snap Components to Anchors", menu: MenuPath(glyphMenu, section: 6), keywords: ["anchor", "component"],
                    validation: needsGlyphs, action: run { SnapComponentsToAnchors($0) }),
            Command(id: GlyphMenuID.decompose, title: "Decompose Components", menu: MenuPath(glyphMenu, section: 6), keywords: ["component", "decompose"],
                    validation: needsGlyphs, action: run { glyphs in CommandBatch("Decompose", glyphs.map { DecomposeComponents($0) }) }),
        ]
        for operation in RewriteGlyphOutlines.Operation.allCases {
            commands.append(Command(id: GlyphMenuID.rewrite(operation), title: operation.title, menu: MenuPath(glyphMenu, section: 6), keywords: ["outline", "clean up"],
                                    validation: needsGlyphs, action: run { RewriteGlyphOutlines($0, operation) }))
        }
        commands.append(Command(id: GlyphMenuID.roundToUnits, title: "Round to Units", menu: MenuPath(glyphMenu, section: 6), keywords: ["round", "integer", "grid"],
                                validation: needsGlyphs, action: run { RoundGlyphsToUnits($0) }))
        for query in GlyphSelectionQuery.allCases {
            commands.append(Command(id: GlyphMenuID.select(query), title: query.title, menu: MenuPath(glyphMenu, "Select", section: 0), keywords: ["select", "glyphs"],
                                    validation: query.needsSelection ? needsGlyphs : needsTypeface,
                                    action: .perform { [unowned self] in selectGlyphs(query) }))
        }
        commands.append(Command(id: GlyphMenuID.showMarkAttachment, title: "Show Mark Attachment",
                                menu: MenuPath(StandardCommands.Menu.view, section: StandardCommands.Section.viewZoom), keywords: ["anchor", "mark", "accent"],
                                validation: { [unowned self] in .checked(showsMarkAttachment) },
                                action: .perform { [unowned self] in toggleMarkAttachment() }))
        return commands
    }

    /// Performs `make`'s command for the targeted glyphs on the font's document (one change).
    @discardableResult
    func performOnTargets(_ make: @MainActor ([OpID]) -> (any WTModel.Command)?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let controller = window() else { return nil }
        let glyphs = targetGlyphs(in: controller)
        guard !glyphs.isEmpty, let command = make(glyphs) else { return nil }
        return gridDocument(of: controller).perform(command)
    }

    /// menu:Glyph[Export Glyph]: every targeted glyph exported when any is not, else none.
    @discardableResult
    func toggleExport() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let controller = window() else { return nil }
        let index = GlyphIndex(gridDocument(of: controller).state)
        let export = targetGlyphs(in: controller).contains { index[$0]?.skipExport == true }
        return performOnTargets { SetGlyphAttributes($0, export: export) }
    }

    /// menu:Glyph[Select]: the glyphs `query` finds, selected in the document's grid.
    @discardableResult
    func selectGlyphs(_ query: GlyphSelectionQuery) -> [OpID] {
        guard let controller = window() else { return [] }
        let document = gridDocument(of: controller)
        let glyphs = query.glyphs(selected: targetGlyphs(in: controller), in: document.state)
        let grid = gridWindow(of: document.id) ?? controller
        mode(of: grid)?.grid?.model.select(glyphs)
        if grid !== controller { grid.showWindow(nil) }
        return glyphs
    }

    /// menu:View[Show Mark Attachment]: on or off for every glyph tab.
    func toggleMarkAttachment() {
        showsMarkAttachment.toggle()
        for mode in modes.values where mode.glyphHandles != nil { mode.controller.canvas.setNeedsOverlayDisplay() }
    }

    /// The Set Advance Width / Left / Right Side Bearing sheet on the front window.
    @discardableResult
    func presentMetricSheet(_ metric: GlyphMetric) -> NSWindow? {
        guard let controller = window() else { return nil }
        let document = gridDocument(of: controller)
        let glyphs = targetGlyphs(in: controller)
        guard !glyphs.isEmpty else { return nil }
        let model = GlyphMetricSheetModel(metric: metric, glyphs: glyphs, state: document.state) { document.perform($0) }
        return present("sheet.glyphMetric", on: controller.window) { close in GlyphMetricSheet(model: model, close: close) }
    }
}

/// The Set Advance Width / Set Left Side Bearing / Set Right Side Bearing sheet (glyph-grid.adoc,
/// "Acting on several glyphs"): *Set to*, *Add* or *Scale by* a percentage, for every glyph.
@MainActor
@Observable
final class GlyphMetricSheetModel {
    enum Mode: Hashable, CaseIterable {
        case set, add, scale

        var title: String {
            switch self {
            case .set: "Set to"
            case .add: "Add"
            case .scale: "Scale by %"
            }
        }
    }

    let metric: GlyphMetric
    let glyphs: [OpID]
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>?
    var mode: Mode = .set
    var value = ""
    private(set) var problem: String?

    static let invalid = "Type a number"

    init(metric: GlyphMetric, glyphs: [OpID], state: EngineState, perform: @escaping @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>?) {
        self.metric = metric
        self.glyphs = glyphs
        self.perform = perform
        // One glyph: its own value to start from.
        if glyphs.count == 1, let metrics = GlyphOutlines.metrics(of: glyphs[0], in: state) {
            switch metric {
            case .width: value = FontUnits.format(metrics.advanceWidth)
            case .left: value = FontUnits.format(metrics.leftSideBearing)
            case .right: value = FontUnits.format(metrics.rightSideBearing)
            }
        }
    }

    var title: String {
        switch metric {
        case .width: "Set Advance Width"
        case .left: "Set Left Side Bearing"
        case .right: "Set Right Side Bearing"
        }
    }

    var subtitle: String { glyphs.count == 1 ? "1 glyph" : "\(glyphs.count) glyphs" }

    /// The adjustment the fields describe, nil when the value is not a number.
    var adjustment: GlyphMetricAdjustment? {
        guard let number = FontUnits.parse(value) else { return nil }
        switch mode {
        case .set: return .set(number)
        case .add: return .add(number)
        case .scale: return .scale(number / 100)
        }
    }

    /// btn:[OK]: one change for every glyph.
    func commit() -> Bool {
        guard let adjustment else {
            problem = Self.invalid
            return false
        }
        problem = nil
        return perform(AdjustGlyphMetrics(glyphs, metric, adjustment)) != nil
    }
}

struct GlyphMetricSheet: View {
    @Bindable var model: GlyphMetricSheetModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline)
            Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $model.mode) {
                ForEach(GlyphMetricSheetModel.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField(model.mode == .scale ? "Percent" : "Font units", text: $model.value).accessibilityIdentifier("glyphMetric.value")
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("OK", action: SheetButtons.closing(model.commit, close)).keyboardShortcut(.defaultAction).accessibilityIdentifier("glyphMetric.ok")
            }
        }
        .padding()
        .frame(width: 320)
    }
}
