import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// Colours between the document's `ColorRef` and AppKit (attribute editors, colour drops).
enum ColorBridge {
    /// The well-known *None*.
    static var none: Wiretuner_Doc_V1_ColorRef {
        var ref = Wiretuner_Doc_V1_ColorRef()
        ref.none = true
        return ref
    }

    static func isNone(_ ref: Wiretuner_Doc_V1_ColorRef) -> Bool {
        if case .none? = ref.ref { return true }
        return false
    }

    /// The colour `ref` shows; nil for *None*.
    static func cgColor(_ ref: Wiretuner_Doc_V1_ColorRef) -> CGColor? {
        Appearances.color(ref)?.cgColor
    }

    /// An unnamed colour for a picked `color`: sRGB when it is inside sRGB, Display P3 otherwise
    /// (a wide-gamut pick keeps its gamut).
    static func ref(_ color: CGColor) -> Wiretuner_Doc_V1_ColorRef {
        var ref = Wiretuner_Doc_V1_ColorRef()
        let extended = color.converted(to: CGColorSpace(name: CGColorSpace.extendedSRGB)!, intent: .defaultIntent, options: nil)
        let srgb = (extended?.components ?? [0, 0, 0]).prefix(3).map(Double.init)
        let inside = srgb.allSatisfy { $0 >= -1e-4 && $0 <= 1 + 1e-4 }
        if inside {
            ref.inline.rgb.r = min(max(srgb[0], 0), 1)
            ref.inline.rgb.g = min(max(srgb[1], 0), 1)
            ref.inline.rgb.b = min(max(srgb[2], 0), 1)
        } else {
            let p3 = color.converted(to: CGColorSpace(name: CGColorSpace.displayP3)!, intent: .defaultIntent, options: nil)
            let components = (p3?.components ?? [0, 0, 0]).prefix(3).map { min(max(Double($0), 0), 1) }
            ref.inline.rgb.r = components[0]
            ref.inline.rgb.g = components[1]
            ref.inline.rgb.b = components[2]
            ref.inline.space = .displayP3
        }
        return ref
    }

    /// A dropped `NSColor`.
    static func ref(_ color: NSColor) -> Wiretuner_Doc_V1_ColorRef {
        ref(color.cgColor)
    }
}

/// The row an editor edits, on every target, with its stored element per target, and the
/// document the edits go to.  Values read through `shared` are nil when the targets differ
/// (the `Mixed` display).
@MainActor
struct AttributeEditorContext {
    let document: DocumentHandle
    let item: AttributeRowItem
    /// The row's element on each target, in target order.
    let entries: [AttributeEntry]
    /// Signals a refused value (a width above the maximum).
    var beep: @MainActor () -> Void = { NSSound.beep() }

    init(document: DocumentHandle, item: AttributeRowItem, entries: [AttributeEntry], beep: @escaping @MainActor () -> Void = { NSSound.beep() }) {
        self.document = document
        self.item = item
        self.entries = entries
        self.beep = beep
    }

    /// The context of `item` in `list`.
    init(list: AttributesListModel, item: AttributeRowItem) {
        self.init(document: list.document, item: item, entries: list.stacks.map { $0[item.index] })
    }

    var pairs: [(node: OpID, row: AppearanceRow)] { item.targets.map(\.pair) }

    /// The value every target shares, or nil.
    func shared<T: Equatable>(_ read: (AttributeEntry) -> T) -> T? {
        WireTuner.shared(entries.map(read))
    }

    /// Performs `command` on the document.
    @discardableResult
    func perform(_ command: (any WTModel.Command)?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        command.map { document.perform($0) }
    }

    /// A control's commit: performs the command `command` makes of the value.
    func committing<Value>(_ command: @escaping (Value) -> any WTModel.Command) -> (Value) -> Void {
        { value in perform(command(value)) }
    }

    /// A slider drag: one undo step from mouse-down to mouse-up.
    func dragging(_ editing: Bool) {
        if editing { document.beginGroup() } else { document.endGroup() }
    }
}

/// Small renders of a stroke or fill for the editors' previews and palettes.
enum AttributePreview {
    static let size = Size(width: 120, height: 36)

    /// A stroke drawn along a gentle S-curve.
    static func stroke(_ paint: StrokePaint, size: Size = size) -> CGImage? {
        var path = DisplayPath()
        path.move(to: Point(x: 10, y: size.height * 0.7))
        path.addCubicCurve(control1: Point(x: size.width * 0.35, y: -size.height * 0.1), control2: Point(x: size.width * 0.65, y: size.height * 1.1),
                           to: Point(x: size.width - 10, y: size.height * 0.3))
        return render(.path(PathItem(path: path, appearance: Appearance([.stroke(paint)]))), size: size)
    }

    /// A fill in a rounded rectangle.
    static func fill(_ paint: FillPaint, size: Size = size) -> CGImage? {
        let path = DisplayPath(rect: Rect(x: 2, y: 2, width: size.width - 4, height: size.height - 4))
        return render(.path(PathItem(path: path, appearance: Appearance([.fill(paint)]))), size: size)
    }

    /// The preview of an attribute row's element on its first target.
    static func image(_ entry: AttributeEntry, size: Size = size) -> CGImage? {
        switch entry.kind {
        case .fill: fill(Appearances.fill(entry.fill.settings, evenOdd: false), size: size)
        case .stroke: stroke(Appearances.stroke(entry.stroke.settings), size: size)
        case .effect: nil
        }
    }

    static func render(_ item: DisplayItem, size: Size) -> CGImage? {
        CoreGraphicsRenderer(background: .white).renderBitmap(DisplayList(canvas: "preview", items: [item]), viewport: Viewport(size: size), scale: 2)
    }
}

/// A preview image, or an empty frame when there is nothing to draw.
struct AttributePreviewImage: View {
    let image: CGImage?
    var size: Size = AttributePreview.size
    let identifier: String

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
            } else {
                SwiftUI.Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
        .border(SwiftUI.Color.secondary.opacity(0.4))
        .accessibilityIdentifier(identifier)
    }
}

/// A colour control of the attribute editors: the shared colour well (COLOR-011) -- chip and
/// palette, the pop-up with *None*, the swatches, *Add to Swatches…*, *Detach* and *Restore*,
/// and the value field -- over `document`'s swatches; "Mixed" when the targets differ.
struct AttributeColorControl: View {
    let title: String
    /// The colour, or nil when the targets differ.
    let color: Wiretuner_Doc_V1_ColorRef?
    let identifier: String
    /// The document the targets are in (its swatches fill the pop-up).
    var document: DocumentHandle?
    let commit: (Wiretuner_Doc_V1_ColorRef) -> Void

    init(title: String, color: Wiretuner_Doc_V1_ColorRef?, identifier: String, document: DocumentHandle? = nil,
         commit: @escaping (Wiretuner_Doc_V1_ColorRef) -> Void) {
        self.title = title
        self.color = color
        self.identifier = identifier
        self.document = document
        self.commit = commit
    }

    var model: ColorWellModel {
        ColorWellModel(ref: color, state: document?.state ?? EngineState(), documentID: document?.id ?? "")
    }

    var body: some View {
        ColorWellView(title: title, model: model, actions: ColorWellActions(document: document, commit: commit), identifier: identifier)
    }
}

/// A checkbox over several targets: on, off or mixed.
struct AttributeToggle: View {
    let title: String
    let value: Bool?
    let identifier: String
    let commit: (Bool) -> Void

    static func binding(_ value: Bool?, commit: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value ?? false }, set: { commit($0) })
    }

    var body: some View {
        Toggle(title, isOn: Self.binding(value, commit: commit))
            .accessibilityIdentifier(identifier)
            .accessibilityValue(value.map { $0 ? "on" : "off" } ?? "mixed")
    }
}

/// A pop-up over several targets; its title reads "Mixed" when they differ.
struct AttributePicker<Value: Hashable>: View {
    let title: String
    let value: Value?
    let choices: [(Value, String)]
    let identifier: String
    let commit: (Value) -> Void

    static func binding(_ value: Value?, fallback: Value, commit: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { value ?? fallback }, set: { commit($0) })
    }

    var body: some View {
        if let fallback = choices.first?.0 {
            Picker(title, selection: Self.binding(value, fallback: fallback, commit: commit)) {
                ForEach(choices, id: \.0) { choice, name in Text(name).tag(choice) }
            }
            .accessibilityIdentifier(identifier)
            .accessibilityValue(value == nil ? "Mixed" : "")
        }
    }
}

/// A slider with a number field: the drag is one undo step, the field commits on Return.
struct AttributeSlider: View {
    let title: String
    let value: Double?
    let range: ClosedRange<Double>
    let identifier: String
    let context: AttributeEditorContext
    let commit: (Double) -> Void

    static func binding(_ value: Double?, range: ClosedRange<Double>, commit: @escaping (Double) -> Void) -> Binding<Double> {
        Binding(get: { min(max(value ?? range.lowerBound, range.lowerBound), range.upperBound) }, set: { commit($0) })
    }

    /// The number field's commit: clamped to the slider's range.
    static func clamping(_ range: ClosedRange<Double>, _ commit: @escaping (Double) -> Void) -> (Double) -> Void {
        { commit(min(max($0, range.lowerBound), range.upperBound)) }
    }

    var body: some View {
        HStack {
            Slider(value: Self.binding(value, range: range, commit: commit), in: range, onEditingChanged: context.dragging) { Text(title) }
                .accessibilityIdentifier(identifier)
            CommitField(title: title, value: value, identifier: "\(identifier).field", commit: Self.clamping(range, commit))
                .frame(width: 56)
        }
    }
}
