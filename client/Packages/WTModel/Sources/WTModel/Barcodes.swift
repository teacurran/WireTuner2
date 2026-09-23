import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Register paths of `BarcodeProps` (kind `barcode` = 240; data-merge.adoc, "Barcodes").
public enum BarcodeFields {
    static let kind = NodeKind.barcode.rawValue
    public static let symbology = RegisterPath([kind, 2])
    public static let value = RegisterPath([kind, 3])
    public static let errorCorrection = RegisterPath([kind, 4])
    public static let quietZone = RegisterPath([kind, 5])
    public static let showText = RegisterPath([kind, 6])
    public static let appearance = RegisterPath([kind, 7])
}

/// Reading barcodes (DATA-018, model half).
public enum Barcodes {
    /// The barcode as WTRender draws it in its local space: unset symbology reads as QR, unset
    /// error correction as M, a quiet zone of 0 as the symbology's default; the bars take the first
    /// fill's paint (black when there is none).  Bound fields are not substituted yet (DATA-003
    /// has no record resolution in WTModel).
    public static func spec(_ props: Wiretuner_Doc_V1_BarcodeProps, appearance: Appearance? = nil) -> BarcodeSpec {
        let levels: [Wiretuner_Doc_V1_QrErrorCorrection: QRErrorCorrection] = [.l: .low, .q: .quartile, .h: .high]
        let paint = appearance?.items.lazy.compactMap { element -> Paint? in
            if case .fill(let fill) = element { return fill.paint }
            return nil
        }.first
        return BarcodeSpec(
            symbology: props.symbology == .code128 ? .code128 : .qr, value: props.value, errorCorrection: levels[props.qrErrorCorrection] ?? .medium,
            quietZone: props.quietZone > 0 ? props.quietZone : nil, showText: props.showText, paint: paint ?? .solid(.black)
        )
    }
}

/// menu:Insert[Barcode…]: a barcode of `value` with its top-left at `point` on top of the active
/// layer, drawn with a black fill ("Insert Barcode").
public struct InsertBarcode: Command {
    public var value: String
    public var symbology: BarcodeSymbology
    public var point: Point
    public var layer: OpID?
    public var label: String { "Insert Barcode" }

    public init(_ value: String, symbology: BarcodeSymbology = .qr, at point: Point = .zero, layer: OpID? = nil) {
        self.value = value
        self.symbology = symbology
        self.point = point
        self.layer = layer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard point.isFinite else { throw ObjectEditError.invalidValue("point") }
        let layer = try PathEditing.ensureLayer(&builder, state: state, preferred: self.layer)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.barcode.symbology = symbology == .qr ? .qr : .code128
        props.barcode.value = String(value.prefix(4096))
        props.barcode.qrErrorCorrection = .m
        if point != .zero { props.barcode.common.transform = PathEditing.proto(AffineTransform.translation(x: point.x, y: point.y)) }
        let node = builder.append(Ops.create(parent: layer, position: try PathEditing.topPosition(in: layer, state: state), props: props))
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [Appearances.basicFill(red: 0, green: 0, blue: 0)]
        for op in try PathEditing.appearanceInserts(node, kind: .barcode, appearancePath: BarcodeFields.appearance, appearance) {
            builder.append(op)
        }
    }
}

/// The Object panel's barcode section: each field given, written on every barcode in one change
/// ("Change barcode", "Change 3 barcodes").
public struct SetBarcodeFields: Command {
    public struct Values: Hashable, Sendable {
        public var symbology: BarcodeSymbology?
        public var value: String?
        public var errorCorrection: QRErrorCorrection?
        public var quietZone: Double?
        public var showText: Bool?

        public init(symbology: BarcodeSymbology? = nil, value: String? = nil, errorCorrection: QRErrorCorrection? = nil, quietZone: Double? = nil,
                    showText: Bool? = nil) {
            self.symbology = symbology
            self.value = value
            self.errorCorrection = errorCorrection
            self.quietZone = quietZone
            self.showText = showText
        }
    }

    public var nodes: [OpID]
    public var values: Values
    public var label: String { nodes.count == 1 ? "Change barcode" : "Change \(nodes.count) barcodes" }

    public init(_ nodes: [OpID], _ values: Values) {
        self.nodes = nodes
        self.values = values
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if let zone = values.quietZone, !(zone.isFinite && zone >= 0) { throw ObjectEditError.invalidValue("quietZone") }
        var props = Wiretuner_Doc_V1_NodeProps()
        var paths: [RegisterPath] = []
        if let symbology = values.symbology {
            props.barcode.symbology = symbology == .qr ? .qr : .code128
            paths.append(BarcodeFields.symbology)
        }
        if let value = values.value {
            props.barcode.value = String(value.prefix(4096))
            paths.append(BarcodeFields.value)
        }
        if let level = values.errorCorrection {
            switch level {
            case .low: props.barcode.qrErrorCorrection = .l
            case .medium: props.barcode.qrErrorCorrection = .m
            case .quartile: props.barcode.qrErrorCorrection = .q
            case .high: props.barcode.qrErrorCorrection = .h
            }
            paths.append(BarcodeFields.errorCorrection)
        }
        if let zone = values.quietZone {
            props.barcode.quietZone = zone
            paths.append(BarcodeFields.quietZone)
        }
        if let showText = values.showText {
            props.barcode.showText = showText
            paths.append(BarcodeFields.showText)
        }
        guard !paths.isEmpty else { return }
        for node in Objects.editable(nodes, in: state) where state.nodeKind(node) == .barcode {
            builder.append(Ops.set(node, paths, values: props))
        }
    }
}

/// menu:Modify[Convert to Paths] on barcodes: each becomes one path of its bars' rectangles in
/// the barcode's place, with the barcode's transform and attribute stack; the barcode is deleted.
/// An unencodable barcode is left alone.
public struct ConvertBarcodesToPaths: Command {
    public var nodes: [OpID]
    public var label: String { "Convert to Paths" }

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Objects.editable(nodes, in: state) where state.nodeKind(node) == .barcode {
            let props = state.props(node).barcode
            let rectangles = BarcodeRendering.paths(Barcodes.spec(props))
            guard !rectangles.isEmpty, let parent = Objects.parent(of: node, in: state) else { continue }
            var bars = DisplayPath()
            for rectangle in rectangles { bars.elements += rectangle.elements }
            var path = Wiretuner_Doc_V1_NodeProps()
            path.path.common = props.common
            path.path.contours = InlineShapes.contours(bars)
            path.path.appearance = props.appearance
            let position = try Arranging.keys(next: node, above: true, count: 1, in: state)[0]
            try NodeCopier.create(NodeTree(props: path), parent: parent, position: position, schema: state.schema, builder: &builder)
            builder.append(Ops.setDeleted(node))
        }
    }
}
