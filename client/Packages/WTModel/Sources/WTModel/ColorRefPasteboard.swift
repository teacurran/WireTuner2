import Foundation
import WTCRDT
import WTProto
import WTRender

/// What a colour drag or copy carries (color-mixer.adoc, "the `ColorRef` pasteboard type";
/// COLOR-008's model half, used by the Mixer, Tints, Swatches and Object panels and the
/// Eyedropper): the encoded `ColorRef`, its resolved `Color` (space included) and name, the
/// document it came from, and for a swatch drag the swatch and its tints as a `ColorLibrary`,
/// so a drop in another document can recreate them.  AppKit registers `typeIdentifier`; the
/// payload is a binary property list of protobuf encodings.
public struct ColorRefPasteboard: Hashable, Sendable {
    /// The pasteboard type (a UTI the app's Info.plist exports).
    public static let typeIdentifier = "com.villagecompute.wiretuner.colorref"

    /// The reference as written in the source document.
    public var ref: Wiretuner_Doc_V1_ColorRef
    /// The colour it resolved to there; nil for *None*.
    public var color: Color?
    /// The swatch name, or "" for an unnamed colour.
    public var name: String
    /// Whether the colour is a spot colour (a spot swatch or a tint of one).
    public var spot: Bool
    /// The source document's id ("" when unknown).
    public var document: String
    /// For a swatch drag: the swatch (and the tints under it) as a library, for a drop in
    /// another document.
    public var library: Wiretuner_Lib_V1_ColorLibrary?

    public init(ref: Wiretuner_Doc_V1_ColorRef, color: Color?, name: String = "", spot: Bool = false, document: String = "",
                library: Wiretuner_Lib_V1_ColorLibrary? = nil) {
        self.ref = ref
        self.color = color
        self.name = name
        self.spot = spot
        self.document = document
        self.library = library
    }

    /// The payload for `ref` read in `list`'s document: a swatch reference carries the swatch's
    /// name, its spot flag and the swatch with its tints as a library.
    public init(ref: Wiretuner_Doc_V1_ColorRef, list: SwatchList, document: String = "") {
        let swatch = ColorResolver.swatch(of: ref).flatMap { list[$0] }
        var name = ""
        var spot = false
        var library: Wiretuner_Lib_V1_ColorLibrary?
        if case .swatch? = ref.ref, let swatch {
            name = swatch.name
            spot = swatch.isSpot
            if !swatch.isProtected {
                library = ColorLibraries.library(named: swatch.plainName, swatches: [swatch.id], list: list)
            }
        } else if case .tint? = ref.ref, let swatch {
            spot = swatch.isSpot
        }
        self.init(ref: ref, color: list.resolver.color(ref), name: name, spot: spot, document: document, library: library)
    }

    /// A drag of the swatch `swatch`.
    public init(swatch: OpID, list: SwatchList, document: String = "") {
        self.init(ref: list.resolver.reference(to: swatch), list: list, document: document)
    }

    /// The colour to hand other applications (`NSColor`): Display P3 when the colour is, sRGB
    /// otherwise (clipped); nil for *None*.
    public var foreignColor: Color? {
        guard let color else { return nil }
        if color.space == .displayP3 { return color.clampedToSpace }
        let rgb = color.srgb
        return Color(red: rgb.x, green: rgb.y, blue: rgb.z)
    }

    /// The reference a drop writes in `document` (state `state`): the carried reference when it
    /// came from this document and its swatch is still live (or it names none); otherwise the
    /// carried colour as an unnamed colour -- a cross-document drop of a swatch creates the
    /// swatch first (`ImportLibraryColors` with `library`) and references it instead.
    public func reference(in state: EngineState, document: String) -> Wiretuner_Doc_V1_ColorRef {
        if case .none? = ref.ref { return ref }
        if document == self.document, let swatch = ColorResolver.swatch(of: ref), ColorResolver(state).isSwatch(swatch) {
            return ref
        }
        if document == self.document, case .inline? = ref.ref { return ref }
        guard let color else { return ColorResolver.none }
        return ColorResolver.inline(color)
    }

    // MARK: Encoding

    private struct Payload: Codable {
        var ref: Data
        var color: Data?
        var name: String
        var spot: Bool
        var document: String
        var library: Data?
    }

    /// The pasteboard data.
    public func data() -> Data {
        let payload = Payload(ref: (try? ref.serializedData()) ?? Data(), color: color.map(ColorValues.cached), name: name, spot: spot,
                              document: document, library: library.flatMap { try? $0.serializedData() })
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return (try? encoder.encode(payload)) ?? Data()
    }

    /// The payload in `data`, or nil when it is not one.
    public init?(data: Data) {
        guard let payload = try? PropertyListDecoder().decode(Payload.self, from: data),
              let ref = try? Wiretuner_Doc_V1_ColorRef(serializedBytes: payload.ref) else { return nil }
        self.init(ref: ref, color: payload.color.flatMap(ColorValues.cachedColor), name: payload.name, spot: payload.spot,
                  document: payload.document, library: payload.library.flatMap { try? Wiretuner_Lib_V1_ColorLibrary(serializedBytes: $0) })
    }
}
