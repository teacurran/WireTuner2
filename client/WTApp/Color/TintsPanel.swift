import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTRender

/// The Tints panel's state and actions (tints.adoc; COLOR-010): the base -- a named colour from
/// the pop-up or a drop, or an unnamed colour dropped on the base well -- the percentage (preset
/// bar, slider and field), the split well (base left, tint right), btn:[Apply] (an unnamed tint
/// of a named base, else the tinted colour), btn:[Add to Swatches] (a named tint; an unnamed base
/// is refused with an offer to add it first), and kbd:[Option]-click loading from the Swatches
/// panel.  The base's colour is read live, so a collaborator's recolour shows while the slider
/// moves.
@MainActor
@Observable
final class TintsModel {
    let workspace: ColorWorkspace
    /// The named base, when there is one.
    private(set) var base: OpID?
    /// An unnamed base colour (dropped on the base well).
    private(set) var unnamedBase: RenderColor?
    /// The tint strength, 1...100.
    private(set) var percent = 50.0
    /// The tint swatch loaded with kbd:[Option]-click, if any.
    private(set) var loadedTint: OpID?
    /// The offer to add an unnamed base first is showing.
    private(set) var offersToAddBase = false

    static let presets: [Double] = [10, 20, 30, 40, 50, 60, 70, 80, 90]

    init(workspace: ColorWorkspace) {
        self.workspace = workspace
    }

    private var list: SwatchList? { workspace.swatches?.list }

    /// The bases the pop-up offers: every colour swatch except Registration (tints.adoc).
    var baseChoices: [Swatch] {
        (list?.swatches ?? []).filter { !$0.isTint && $0.role != .registration }
    }

    /// The base colour as it is now (a loaded tint whose base was removed reads the colour it
    /// cached); nil with no base.
    var baseColor: RenderColor? {
        guard let base, let list else { return unnamedBase }
        if let live = list.resolver.color(ofSwatch: base) { return live }
        return loadedTint.flatMap { list.resolver.props($0) }.flatMap { ColorValues.cachedColor($0.parent.cached) }
    }

    /// The base's name, for the pop-up.
    var baseName: String? { base.flatMap { list?[$0]?.name } }

    /// The tint the right half of the well shows.
    var tint: RenderColor? { baseColor?.tinted(percent / 100) }

    /// Whether the loaded tint's base was removed (the badge).
    var baseRemoved: Bool { loadedTint.flatMap { list?[$0]?.baseRemoved } ?? false }

    // MARK: Choosing

    /// The pop-up: a named base.
    func choose(base id: OpID?) {
        base = id
        unnamedBase = nil
        loadedTint = nil
        offersToAddBase = false
    }

    /// The preset bar, the slider and the field.
    func setPercent(_ value: Double) {
        percent = ColorResolver.percent(value)
    }

    /// kbd:[Option]-click in the Swatches panel: a tint loads its base and percentage, a colour
    /// becomes the base.
    func load(_ id: OpID) {
        guard let swatch = list?[id] else { return }
        if let parent = swatch.base {
            base = parent
            percent = swatch.tintPercent
            loadedTint = id
        } else {
            choose(base: id)
        }
        unnamedBase = nil
    }

    /// A colour dropped on the base well: a swatch of this document becomes the named base, any
    /// other colour an unnamed base.
    @discardableResult
    func dropBase(from pasteboard: NSPasteboard) -> Bool {
        guard let payload = ColorDrag.read(from: pasteboard, defaultSpace: workspace.defaultSpace) else { return false }
        if case .swatch? = payload.ref.ref, payload.document == workspace.document?.id, let id = ColorResolver.swatch(of: payload.ref), list?[id] != nil {
            load(id)
            return true
        }
        guard let color = payload.color else { return false }
        choose(base: nil)
        unnamedBase = color
        return true
    }

    // MARK: Applying and adding

    /// The reference btn:[Apply] writes: an unnamed tint of the named base, else the tinted
    /// colour.
    var reference: Wiretuner_Doc_V1_ColorRef? {
        if let base, let list, list[base] != nil { return list.resolver.tint(of: base, percent: percent) }
        return tint.map(ColorResolver.inline)
    }

    @discardableResult
    func apply() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        reference.flatMap { workspace.apply($0) }
    }

    /// btn:[Add to Swatches]: a named tint of the base (its derived name); an unnamed base is
    /// refused with the offer to add it first.
    @discardableResult
    func addToSwatches() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        if let base, list?[base] != nil {
            return workspace.perform(AddTintSwatch(of: base, percent: percent))
        }
        offersToAddBase = unnamedBase != nil
        return nil
    }

    /// The offer's btn:[Add Base]: adds the unnamed base as a colour, makes it the base, then
    /// adds the tint.
    @discardableResult
    func addBaseAndTint() -> Task<Void, Never>? {
        guard let color = unnamedBase, let document = workspace.document else { return nil }
        offersToAddBase = false
        let adding = document.perform(AddSwatch(color))
        return Task { @MainActor in
            if let change = await adding.value {
                self.choose(base: ColorWellActions.created(by: change))
                _ = await self.addToSwatches()?.value
            }
        }
    }

    func declineAddingBase() {
        offersToAddBase = false
    }

    /// Dragging the tint well carries the reference btn:[Apply] would write (a drop on a tint
    /// swatch of the same base sets its percentage).
    var dragPayload: ColorRefPasteboard? {
        guard let reference, let tint else { return nil }
        return ColorRefPasteboard(ref: reference, color: tint, document: workspace.document?.id ?? "")
    }
}

/// The Tints panel body.
struct TintsPanelBody: View {
    let model: TintsModel

    static func baseBinding(_ model: TintsModel) -> Binding<OpID?> {
        Binding(get: { model.base }, set: { model.choose(base: $0) })
    }

    static func percentBinding(_ model: TintsModel) -> Binding<Double> {
        Binding(get: { model.percent }, set: { model.setPercent($0) })
    }

    static func preset(_ value: Double, _ model: TintsModel) -> () -> Void {
        { model.setPercent(value) }
    }

    static func dropping(_ model: TintsModel, pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> ([NSItemProvider]) -> Bool {
        { _ in model.dropBase(from: pasteboard) }
    }

    static func dragging(_ model: TintsModel) -> () -> NSItemProvider {
        { model.dragPayload.map(ColorDrag.itemProvider) ?? NSItemProvider() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Base", selection: Self.baseBinding(model)) {
                Text("None").tag(OpID?.none)
                ForEach(model.baseChoices) { swatch in Text(swatch.name).tag(OpID?.some(swatch.id)) }
            }
            .accessibilityIdentifier("tints.base")
            HStack(spacing: 2) {
                ForEach(TintsModel.presets, id: \.self) { value in
                    Button(action: Self.preset(value, model)) {
                        ColorChipView(chip: model.baseColor.map { .color($0.tinted(value / 100)) } ?? .none, size: CGSize(width: 16, height: 16))
                    }
                    .buttonStyle(.plain)
                    .help("\(Int(value))%")
                    .accessibilityIdentifier("tints.preset.\(Int(value))")
                }
            }
            HStack {
                Slider(value: Self.percentBinding(model), in: 1...100).accessibilityIdentifier("tints.slider")
                CommitField(title: "%", value: model.percent, identifier: "tints.percent", commit: model.setPercent).frame(width: 50)
            }
            HStack(spacing: 0) {
                if model.workspace.splitColorBox {
                    ColorChipView(chip: model.baseColor.map(ColorWellModel.Chip.color) ?? .none, size: CGSize(width: 40, height: 28))
                        .onDrop(of: ColorDrag.dropTypes, isTargeted: nil, perform: Self.dropping(model))
                        .accessibilityIdentifier("tints.base-well")
                }
                ColorChipView(chip: model.tint.map(ColorWellModel.Chip.color) ?? .none, size: CGSize(width: model.workspace.splitColorBox ? 40 : 80, height: 28))
                    .onDrag(Self.dragging(model))
                    .onDrop(of: ColorDrag.dropTypes, isTargeted: nil, perform: Self.dropping(model))
                    .accessibilityIdentifier("tints.well")
                if model.baseRemoved {
                    Image(systemName: "exclamationmark.triangle").help("Base color removed").padding(.leading, 6).accessibilityIdentifier("tints.base-removed")
                }
            }
            .panelContextMenu(.tint)
            if model.offersToAddBase {
                Text("The base color is not named.  Add it to the Swatches panel first?").font(.caption)
                HStack {
                    Button("Not Now", action: model.declineAddingBase)
                    Button("Add Base", action: ColorAction.run(model.addBaseAndTint)).accessibilityIdentifier("tints.add-base")
                }
            }
            HStack {
                Button("Apply", action: ColorAction.run(model.apply)).accessibilityIdentifier("tints.apply")
                Button("Add to Swatches", action: ColorAction.run(model.addToSwatches)).accessibilityIdentifier("tints.add")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
