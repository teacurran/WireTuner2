import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Character section's *Axes* and *Features* groups (type-specifications.adoc, "Variable font
/// axes" and "OpenType features"; TYPE-046), as the section after the Character section.  *Axes*
/// shows for a variable face: a slider and a field per axis (the slider writes once, when the drag
/// ends: one `axes` mark carrying the whole tuple), a reset arrow to the axis's default, *Auto* for
/// `opsz` (no `opsz` in the tuple) and the named instances with *Custom* (an instance writes
/// `font_style` and `axes` in one change).  *Features* lists the documented features the face
/// offers, each a tri-state -- the font's default, on, off -- with a reset arrow that writes
/// `DEFAULT`.  At an insertion point both go to the Text tool's pending format.
extension ObjectPanelModel {
    struct AxisRow: Equatable {
        let offer: FontAxisOffer
        /// The shared value; nil when the text differs.
        let value: Double?
        /// Whether the tuple leaves the axis out (for `opsz`, *Auto*).
        let isAuto: Bool
    }

    struct FeatureRow: Equatable {
        let tag: String
        let title: String
        /// The effective state; `.mixed` when the text differs.
        let isOn: MixedState
        /// Whether some text sets it explicitly (the reset arrow shows).
        let isSet: Bool
    }

    struct VariationSection: Equatable {
        let family: String
        let style: String
        let axes: [AxisRow]
        let instances: [FontInstanceOffer]
        /// The instance every run is at, "Custom" when the axes are elsewhere, nil when mixed.
        let instance: String?
        let features: [FeatureRow]
    }

    static let custom = "Custom"

    /// The features on by default in most fonts.
    static let defaultOnFeatures: Set<String> = ["liga", "calt"]

    /// Offers per face, read once.
    @MainActor private static var offerCache: [String: (axes: [FontAxisOffer], instances: [FontInstanceOffer], features: [String], names: [String: String])] = [:]

    @MainActor static func offers(family: String, style: String) -> (axes: [FontAxisOffer], instances: [FontInstanceOffer], features: [String], names: [String: String]) {
        let key = "\(family)\u{1F}\(style)"
        if let cached = offerCache[key] { return cached }
        let font = FontOffers.font(family: family, style: style)
        let axes = font.map(FontOffers.axes) ?? []
        let result = (axes, axes.isEmpty ? [] : FontOffers.instances(family: family), FontOffers.features(family: family, style: style),
                      font.map(FontOffers.stylisticSetNames) ?? [:])
        offerCache[key] = result
        return result
    }

    /// The axis values a run shows: its `axes` mark over its instance's values over the defaults.
    static func tuple(_ values: [Wiretuner_Doc_V1_TextMarkValue], axes: [FontAxisOffer], instances: [FontInstanceOffer]) -> [String: Double] {
        var result = Dictionary(uniqueKeysWithValues: axes.map { ($0.tag, $0.defaultValue) })
        if let instance = instances.first(where: { $0.style == style(values) }) {
            for (tag, value) in instance.axes where result[tag] != nil { result[tag] = value }
        }
        for value in values {
            if case .axes(let variation)? = value.value {
                for axis in variation.axes where result[axis.tag] != nil { result[axis.tag] = axis.value }
            }
        }
        return result
    }

    /// Whether a run's `axes` mark leaves `tag` out.
    static func leavesOut(_ values: [Wiretuner_Doc_V1_TextMarkValue], _ tag: String) -> Bool {
        for value in values { if case .axes(let variation)? = value.value { return !variation.axes.contains { $0.tag == tag } } }
        return true
    }

    /// A run's state for feature `tag`.
    static func featureState(_ values: [Wiretuner_Doc_V1_TextMarkValue], _ tag: String) -> Wiretuner_Doc_V1_FeatureState {
        for value in values { if case .feature(let feature)? = value.value, feature.tag == tag { return feature.state } }
        return .unspecified
    }

    static func effective(_ state: Wiretuner_Doc_V1_FeatureState, _ tag: String) -> Bool {
        switch state {
        case .on: true
        case .off: false
        default: defaultOnFeatures.contains(tag)
        }
    }

    private var variationRuns: [[Wiretuner_Doc_V1_TextMarkValue]] {
        if let session = editingText { return session.formatRuns }
        return targetRuns
    }

    var variations: VariationSection? {
        guard let section = text, let family = section.family, let style = section.style else { return nil }
        let offers = Self.offers(family: family, style: style)
        guard !offers.axes.isEmpty || !offers.features.isEmpty else { return nil }
        let runs = variationRuns
        let tuples = runs.map { Self.tuple($0, axes: offers.axes, instances: offers.instances) }
        let axes = offers.axes.map { offer in
            let values = Set(tuples.map { $0[offer.tag] ?? offer.defaultValue })
            return AxisRow(offer: offer, value: values.count == 1 ? values.first : nil, isAuto: runs.allSatisfy { Self.leavesOut($0, offer.tag) })
        }
        // The instance a run stands at: its own face when that is one, else any at the same values.
        let instanceNames = Set(zip(runs, tuples).map { run, tuple in
            let named = offers.instances.filter { $0.axes == tuple }
            return (named.first { $0.style == Self.style(run) } ?? named.first)?.style ?? Self.custom
        })
        let features = offers.features.map { tag in
            let states = runs.map { Self.featureState($0, tag) }
            return FeatureRow(tag: tag, title: FontOffers.title(tag, names: offers.names), isOn: MixedState(states.map { Self.effective($0, tag) }),
                              isSet: states.contains { $0 == .on || $0 == .off })
        }
        return VariationSection(family: family, style: style, axes: axes, instances: offers.instances,
                                instance: instanceNames.count == 1 ? instanceNames.first : nil, features: features)
    }

    /// Formats with several marks in one change: the Text tool's selection, its pending format at
    /// an insertion point, else every selected block whole.
    @discardableResult
    func formatText(_ values: [Wiretuner_Doc_V1_TextMarkValue], label: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        if let session = editingText, session.selectedRange.isEmpty {
            var result: Task<Wiretuner_Doc_V1_Change?, Never>?
            for value in values { result = session.format(value) }
            return result
        }
        let targets = textTargets
        guard !targets.isEmpty, !values.isEmpty else { return nil }
        return perform(CommandBatch(label, targets.flatMap { target in values.map { ApplyMark(node: target.node, from: target.from, to: target.to, value: $0) } }))
    }

    static func axesValue(_ tuple: [String: Double], order: [FontAxisOffer], leaving: Set<String> = []) -> Wiretuner_Doc_V1_TextMarkValue {
        .with {
            $0.axes = .with { variation in
                variation.axes = order.filter { tuple[$0.tag] != nil && !leaving.contains($0.tag) }.map { offer in
                    .with {
                        $0.tag = offer.tag
                        $0.value = offer.clamped(tuple[offer.tag]!)
                    }
                }
            }
        }
    }

    /// The tuple the first run shows, which a new value is written over.
    private func baseTuple(_ section: VariationSection) -> [String: Double] {
        let offers = Self.offers(family: section.family, style: section.style)
        return Self.tuple(variationRuns[0], axes: offers.axes, instances: offers.instances)
    }

    /// The axes a new tuple leaves out: `opsz` while it is *Auto*.
    static func autoAxes(_ section: VariationSection) -> Set<String> {
        section.axes.contains { $0.isAuto && $0.offer.tag == "opsz" } ? ["opsz"] : []
    }

    /// An axis moved (the slider's end, the field's commit): one `axes` mark with the whole tuple.
    @discardableResult
    func setAxis(_ tag: String, _ value: Double) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let section = variations, value.isFinite, section.axes.contains(where: { $0.offer.tag == tag }) else { return nil }
        var tuple = baseTuple(section)
        tuple[tag] = value
        var leaving = Self.autoAxes(section)
        leaving.remove(tag)
        return formatText([Self.axesValue(tuple, order: section.axes.map(\.offer), leaving: leaving)], label: "Axes")
    }

    /// The reset arrow: the axis back at the font's default.
    @discardableResult
    func resetAxis(_ tag: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let row = variations?.axes.first(where: { $0.offer.tag == tag }) else { return nil }
        return setAxis(tag, row.offer.defaultValue)
    }

    /// *Auto* for optical size: on leaves `opsz` out of the tuple; off pins it at the type size.
    @discardableResult
    func setAutoOpticalSize(_ on: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let section = variations, section.axes.contains(where: { $0.offer.tag == "opsz" }) else { return nil }
        if !on { return setAxis("opsz", text?.size ?? Self.defaultSize) }
        return formatText([Self.axesValue(baseTuple(section), order: section.axes.map(\.offer), leaving: ["opsz"])], label: "Axes")
    }

    /// A named instance picked: `font_style` and the instance's `axes`, one change.
    @discardableResult
    func setInstance(_ style: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let section = variations, let instance = section.instances.first(where: { $0.style == style }) else { return nil }
        return formatText([.with { $0.fontStyle = style }, Self.axesValue(instance.axes, order: section.axes.map(\.offer))], label: "Font Style")
    }

    /// A feature ticked (`ON`), unticked (`OFF`) or reset (`DEFAULT`).
    @discardableResult
    func setFeature(_ tag: String, _ state: Wiretuner_Doc_V1_FeatureState) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard text != nil else { return nil }
        return formatText([.with { $0.feature = .with { $0.tag = tag; $0.state = state } }], label: "OpenType Feature")
    }

    // MARK: Font style

    /// menu:Text[Style]: Plain, Bold, Italic, Bold Italic.  On a variable family with a weight
    /// axis, Bold moves `wght` to the bold instance's weight (with its `font_style`), so nothing
    /// is synthesized; otherwise the face is chosen by name.
    @discardableResult
    func setFontStyleNamed(_ name: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let section = text, let family = section.family else { return nil }
        let offers = Self.offers(family: family, style: section.style ?? Self.defaultStyle)
        if offers.axes.contains(where: { $0.tag == "wght" }), let instance = offers.instances.first(where: { $0.style == name }) {
            return formatText([.with { $0.fontStyle = name }, Self.axesValue(instance.axes, order: offers.axes)], label: "Font Style")
        }
        return formatText([.with { $0.fontStyle = name }], label: "Font Style")
    }
}

/// The groups' view.
struct VariationSectionView: View {
    let section: ObjectPanelModel.VariationSection
    let model: ObjectPanelModel

    static func instance(_ section: ObjectPanelModel.VariationSection, _ model: ObjectPanelModel) -> Binding<String> {
        Binding(get: { section.instance ?? TextSectionView.mixed }, set: { if $0 != ObjectPanelModel.custom { model.setInstance($0) } })
    }

    static func feature(_ row: ObjectPanelModel.FeatureRow, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { row.isOn.isOn }, set: { model.setFeature(row.tag, $0 ? .on : .off) })
    }

    static func resetFeature(_ row: ObjectPanelModel.FeatureRow, _ model: ObjectPanelModel) -> () -> Void {
        { model.setFeature(row.tag, .default) }
    }

    static func auto(_ row: ObjectPanelModel.AxisRow, _ model: ObjectPanelModel) -> Binding<Bool> {
        Binding(get: { row.isAuto }, set: { model.setAutoOpticalSize($0) })
    }

    var body: some View {
        Form {
            if !section.axes.isEmpty {
                Section("Axes") {
                    Picker("Style", selection: Self.instance(section, model)) {
                        if section.instance == nil { Text(TextSectionView.mixed).tag(TextSectionView.mixed) }
                        ForEach(section.instances, id: \.style) { Text($0.style).tag($0.style) }
                        Text(ObjectPanelModel.custom).tag(ObjectPanelModel.custom)
                    }
                    .accessibilityIdentifier("object.axes.instance")
                    ForEach(section.axes, id: \.offer.tag) { row in
                        AxisRowView(row: row, model: model)
                    }
                }
            }
            if !section.features.isEmpty {
                Section("Features") {
                    ForEach(section.features, id: \.tag) { row in
                        HStack {
                            Toggle(row.title, isOn: Self.feature(row, model)).accessibilityIdentifier("object.feature.\(row.tag)")
                            if row.isSet {
                                Button("Reset", systemImage: "arrow.uturn.backward", action: Self.resetFeature(row, model))
                                    .labelStyle(.iconOnly).accessibilityIdentifier("object.feature.\(row.tag).reset")
                            }
                        }
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal)
    }
}

/// One axis: slider (written when the drag ends), field, reset arrow, *Auto* for `opsz`.
struct AxisRowView: View {
    let row: ObjectPanelModel.AxisRow
    let model: ObjectPanelModel
    @State private var draft: Double?

    static func slider(_ row: ObjectPanelModel.AxisRow, draft: Binding<Double?>) -> Binding<Double> {
        Binding(get: { draft.wrappedValue ?? row.value ?? row.offer.defaultValue }, set: { draft.wrappedValue = $0 })
    }

    /// The reset arrow.
    static func reset(_ row: ObjectPanelModel.AxisRow, _ model: ObjectPanelModel) -> () -> Void {
        { model.resetAxis(row.offer.tag) }
    }

    /// The field's commit.
    static func commit(_ row: ObjectPanelModel.AxisRow, _ model: ObjectPanelModel) -> (Double) -> Void {
        { model.setAxis(row.offer.tag, $0) }
    }

    /// The slider's editing callback: the drag's end writes the value once.
    static func editing(_ row: ObjectPanelModel.AxisRow, _ model: ObjectPanelModel, draft: Binding<Double?>) -> (Bool) -> Void {
        { editing in
            guard !editing, let value = draft.wrappedValue else { return }
            draft.wrappedValue = nil
            model.setAxis(row.offer.tag, value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.offer.name)
                Spacer()
                if row.offer.tag == "opsz" {
                    Toggle("Auto", isOn: VariationSectionView.auto(row, model)).accessibilityIdentifier("object.axis.opsz.auto")
                }
                Button("Reset", systemImage: "arrow.uturn.backward", action: Self.reset(row, model))
                    .labelStyle(.iconOnly).accessibilityIdentifier("object.axis.\(row.offer.tag).reset")
            }
            HStack {
                Slider(value: Self.slider(row, draft: $draft), in: row.offer.minimum...max(row.offer.maximum, row.offer.minimum + 0.0001),
                       onEditingChanged: Self.editing(row, model, draft: $draft))
                    .accessibilityIdentifier("object.axis.\(row.offer.tag)")
                CommitField(title: "", value: row.value, identifier: "object.axis.\(row.offer.tag).value", commit: Self.commit(row, model))
                    .frame(width: 70)
            }
        }
    }
}

/// menu:Text[Style]'s four commands (the catalog's stubs), Bold through `wght` on a variable face.
@MainActor
enum FontStyleCommands {
    /// Each command: its id, its title, the face it asks for.
    static let styles = [("plain", "Plain", "Regular"), ("bold", "Bold", "Bold"), ("italic", "Italic", "Italic"), ("boldItalic", "Bold Italic", "Bold Italic")]

    static func commands(window: @escaping @MainActor () -> DocumentWindowController?) -> [Command] {
        styles.map { id, title, name in
            Command(id: ContextMenuCatalog.ID.style(id), title: title,
                    menu: MenuPath(ContextMenuCatalog.Menu.text, "Style", section: 1), contexts: [.text, .textEditing],
                    validation: { model(window()) == nil ? .disabled("Select text") : .enabled },
                    action: .perform { model(window())?.setFontStyleNamed(name) })
        }
    }

    /// The Object panel model of `window`'s selection and Text tool.
    static func model(_ window: DocumentWindowController?) -> ObjectPanelModel? {
        guard let window else { return nil }
        let model = ObjectPanelModel(document: window.documentHandle, selection: window.selection.selection, textSession: window.objectEditing.textSession)
        return model.text == nil ? nil : model
    }
}

/// The axes and features of a text style's Style Behavior sheet, each *No selection* until set.
struct StyleVariationControls: View {
    @Bindable var model: TextStyleBehaviorModel

    /// The registers the sheet compares: the axes tuple and each feature.
    static let fields: [TextStyleBehaviorModel.Field] = [
        TextStyleBehaviorModel.Field(path: [2, 14]) { $0.character.hasAxes == $1.character.hasAxes && $0.character.axes == $1.character.axes },
    ] + FontOffers.featureTags.compactMap { tag in
        Wiretuner_Doc_V1_FeatureSettings.field(tag).map { field in
            TextStyleBehaviorModel.Field(path: [2, 15, field]) { $0.character.features.state(tag) == $1.character.features.state(tag) }
        }
    }

    static let states: [(String, Wiretuner_Doc_V1_FeatureState?)] = [(TextStyleBehaviorModel.noSelection, nil), ("Default", .default), ("On", .on), ("Off", .off)]

    /// The face the controls read: the style's, else Helvetica.
    static func offers(_ model: TextStyleBehaviorModel) -> (axes: [FontAxisOffer], instances: [FontInstanceOffer], features: [String], names: [String: String]) {
        let character = model.attrs.character
        return ObjectPanelModel.offers(family: character.hasFontFamily ? character.fontFamily : ObjectPanelModel.defaultFamily,
                                       style: character.hasFontStyle ? character.fontStyle : ObjectPanelModel.defaultStyle)
    }

    /// An axis field: empty is *No selection* for the whole tuple; a value sets the tuple (the
    /// other axes at their defaults, or as set).
    static func axis(_ offer: FontAxisOffer, _ model: TextStyleBehaviorModel, order: [FontAxisOffer]) -> Binding<String> {
        TextStyleBehaviorModel.number({
            model.attrs.character.hasAxes ? model.attrs.character.axes.axes.first { $0.tag == offer.tag }?.value : nil
        }, { value in
            guard let value else { return model.attrs.character.clearAxes() }
            var tuple = Dictionary(uniqueKeysWithValues: order.map { ($0.tag, $0.defaultValue) })
            for axis in model.attrs.character.axes.axes { tuple[axis.tag] = axis.value }
            tuple[offer.tag] = value
            if case .axes(let variation)? = ObjectPanelModel.axesValue(tuple, order: order).value { model.attrs.character.axes = variation }
        })
    }

    static func feature(_ tag: String, _ model: TextStyleBehaviorModel) -> Binding<String> {
        Binding(get: { states.first { $0.1 == model.attrs.character.features.state(tag) }?.0 ?? TextStyleBehaviorModel.noSelection },
                set: { title in model.attrs.character.features.set(tag, states.first { $0.0 == title }?.1 ?? nil) })
    }

    var body: some View {
        let offers = Self.offers(model)
        ForEach(offers.axes, id: \.tag) { offer in
            TextField(offer.name, text: Self.axis(offer, model, order: offers.axes)).accessibilityIdentifier("behavior.axis.\(offer.tag)")
        }
        ForEach(offers.features, id: \.self) { tag in
            Picker(FontOffers.title(tag, names: offers.names), selection: Self.feature(tag, model)) {
                ForEach(Self.states, id: \.0) { Text($0.0).tag($0.0) }
            }
            .accessibilityIdentifier("behavior.feature.\(tag)")
        }
    }
}
