import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// A gradient fill's ramp on the drag pasteboard (gradients.adoc, "To keep a finished gradient
/// for reuse": drag the ramp to the Swatches panel): the document, the object and its Gradient
/// fill row, under `com.villagecompute.wiretuner.gradient-ramp`.  Only the document it came from
/// takes it, so the stops' swatch references stay valid.
struct GradientRampDrag: Equatable {
    static let typeIdentifier = "com.villagecompute.wiretuner.gradient-ramp"
    static let type = NSPasteboard.PasteboardType(typeIdentifier)
    static let utType = UTType(exportedAs: typeIdentifier)

    let document: String
    let node: OpID
    let row: AppearanceRow

    /// The payload as bytes: the document, then the node's, the list's and the element's numbers,
    /// one per line.
    var data: Data {
        Data([document, "\(node.replica)", "\(node.counter)", "\(row.list.rawValue)", "\(row.element.replica)", "\(row.element.counter)"]
            .joined(separator: "\n").utf8)
    }

    init(document: String, node: OpID, row: AppearanceRow) {
        self.document = document
        self.node = node
        self.row = row
    }

    init?(data: Data) {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let numbers = lines.dropFirst().compactMap { UInt64($0) }
        guard lines.count == 6, numbers.count == 5, let list = AppearanceList(rawValue: UInt32(truncatingIfNeeded: numbers[2])) else { return nil }
        document = lines[0]
        node = OpID(counter: numbers[1], replica: numbers[0])
        row = AppearanceRow(list, OpID(counter: numbers[4], replica: numbers[3]))
    }

    var itemProvider: NSItemProvider {
        NSItemProvider(item: data as NSData, typeIdentifier: Self.typeIdentifier)
    }

    static func read(from pasteboard: NSPasteboard) -> GradientRampDrag? {
        pasteboard.data(forType: type).flatMap(GradientRampDrag.init(data:))
    }
}

/// The Swatches panel's gradient swatches (ATTR-029; swatches.adoc, "The panel"): listed after the
/// colours, each with a chip filled with its gradient (stop swatches resolved live); a ramp dropped
/// on the panel adds one; a click with objects selected applies it to their fills.
extension SwatchesPanelModel {
    /// The front document's gradient swatches, in list order.
    var gradientSwatches: [GradientSwatch] {
        _ = swatches?.revision
        guard let document = workspace.document else { return [] }
        return GradientSwatches.list(in: document.state)
    }

    /// A gradient swatch's chip: a rectangle filled with its gradient.
    func gradientChip(_ id: OpID, size: Size = Size(width: 16, height: 12)) -> CGImage? {
        guard let document = workspace.document, let gradient = GradientSwatches.gradient(id, in: document.state) else { return nil }
        let item = DisplayItem.path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: size.width, height: size.height)),
                                             appearance: Appearance([.fill(FillPaint(paint: .gradient(gradient)))])))
        return CoreGraphicsRenderer(background: .white).renderBitmap(DisplayList(canvas: "gradient-chip", items: [item]), viewport: Viewport(size: size), scale: 2)
    }

    /// A click on a gradient swatch: applied to the selected objects' fills (one change); with
    /// nothing selected, nothing happens.
    @discardableResult
    func clickGradient(_ id: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let nodes = workspace.selectedNodes
        guard !nodes.isEmpty else { return nil }
        return workspace.perform(ApplyGradientSwatch(id, to: nodes))
    }

    /// A ramp dropped on the panel: a gradient swatch of that fill.
    @discardableResult
    func dropRamp(_ ramp: GradientRampDrag) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let document = workspace.document, ramp.document == document.id,
              let command = try? AddGradientSwatch(node: ramp.node, row: ramp.row, in: document.state) else { return nil }
        return workspace.perform(command)
    }

    /// A ramp read from the drag pasteboard; false when it carries none.
    @discardableResult
    func dropRamp(from pasteboard: NSPasteboard) -> Bool {
        guard let ramp = GradientRampDrag.read(from: pasteboard) else { return false }
        return dropRamp(ramp) != nil
    }
}

/// The gradient swatches under the colours in the list.
struct GradientSwatchRows: View {
    let model: SwatchesPanelModel

    static func clicking(_ id: OpID, _ model: SwatchesPanelModel) -> () -> Void {
        { model.clickGradient(id) }
    }

    var body: some View {
        ForEach(model.gradientSwatches, id: \.id) { swatch in
            Button(action: Self.clicking(swatch.id, model)) {
                HStack(spacing: 6) {
                    GradientChipView(image: model.gradientChip(swatch.id))
                    Text(swatch.name)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("swatches.gradient.\(swatch.name)")
        }
    }
}

/// A gradient chip, or an empty frame.
struct GradientChipView: View {
    let image: CGImage?
    var size = CGSize(width: 16, height: 12)

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
            } else {
                Rectangle().stroke(SwiftUI.Color.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The gradient form's handle for dragging its ramp to the Swatches panel.
struct GradientRampHandle: View {
    let model: GradientEditorModel

    static func dragging(_ model: GradientEditorModel) -> () -> NSItemProvider {
        {
            guard let target = model.target else { return NSItemProvider() }
            return GradientRampDrag(document: model.context.document.id, node: target.node, row: target.row).itemProvider
        }
    }

    var body: some View {
        Image(systemName: "square.and.arrow.down.on.square")
            .help("Drag to the Swatches panel to keep this gradient")
            .onDrag(Self.dragging(model))
            .accessibilityIdentifier("fill.gradient.ramp-handle")
    }
}

extension SwatchesPanelBody {
    /// What the Add arrow and the space below the list take: colours, and gradient ramps.
    static let addDropTypes = ColorDrag.dropTypes + [GradientRampDrag.utType]
}
