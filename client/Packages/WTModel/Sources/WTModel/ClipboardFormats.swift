import Foundation
import WTCRDT
import WTInterchange
import WTRender

/// The document half of the interchange clipboard formats (OBJ-015, copying.adoc "Clipboard
/// formats"): a Copy's selection captured as the export scene `WTInterchange.ClipboardWriter`
/// writes as PDF, SVG, TIFF/PNG, RTF and plain text, with the native `ClipboardPayload` beside
/// it.  Pasting a foreign format goes through `WTInterchange.ClipboardReader` and the import path
/// (`PlaceImportedScene`), as a pasted PDF or image already does (importing.adoc, "Pasting").
public enum ClipboardExport {
    /// The live objects `nodes` of `state` as one export page cropped to their bounds, with the
    /// text they hold (the selection scope of `ExportSnapshot`).  `builder` draws the scene (the
    /// window's, with its text layout); `blob` answers a placed image's bytes by SHA-256.
    public static func scene(of nodes: [OpID], in state: EngineState, builder: DocumentDisplayListBuilder,
                             blob: @escaping (Data) -> Data?) -> ExportScene {
        let objects = nodes.filter { Objects.isObject($0, in: state) }
        let request = ExportSnapshot.Request(name: "Clipboard", pages: [], scope: .selection(Set(objects.map(NodeID.init))), text: true)
        return ExportSnapshot.capture(state, request: request, builder: builder, blob: blob).scene
    }

    /// What a Copy of `nodes` offers: the native payload (`document` is the source document's
    /// id) and every format `settings` enables that the selection can fill.
    public static func writer(copying nodes: [OpID], in state: EngineState, document: String = "", builder: DocumentDisplayListBuilder,
                              settings: ClipboardSettings = ClipboardSettings(), blob: @escaping (Data) -> Data?) -> ClipboardWriter {
        let payload = ClipboardPayload(copying: nodes, from: state, document: document)
        return ClipboardWriter(scene: scene(of: nodes, in: state, builder: builder, blob: blob), settings: settings,
                               native: payload.isEmpty ? nil : Data(payload.encoded()))
    }
}
