import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Register paths of `PlacedFileProps` (kind `placed_file` = 171, import-formats.adoc "Data model").
public enum PlacedFileFields {
    public static let kind = NodeKind.placedFile.rawValue
    /// `content`: one ATOMIC register (the file, its preview and its bounding box together).
    public static let content = RegisterPath([kind, 2])
}

/// Reading placed files (IMG-011): a `placed_file` node as WTRender's `PlacedFileDrawing` draws
/// it -- the preview if its pixels are cached, else the gray box with the file's name.
public enum PlacedFiles {
    /// The drawing input of `props` under `transform` (the node's own transform): the content's
    /// bounds, the preview's hex SHA-256 as its asset id (none when the content has no preview),
    /// the preview's pixel size and `source_name`.
    public static func placedFile(_ props: Wiretuner_Doc_V1_PlacedFileProps, transform: AffineTransform) -> PlacedFile {
        let content = props.content
        let bounds = Rect(x: content.bounds.x, y: content.bounds.y, width: content.bounds.width, height: content.bounds.height)
        let preview = content.previewSha256.isEmpty ? nil : hex(content.previewSha256)
        return PlacedFile(bounds: bounds, previewAssetID: preview, previewWidth: Int(content.previewWidth),
                          previewHeight: Int(content.previewHeight), name: content.sourceName, transform: transform)
    }

    /// Lower-case hex of `bytes`: a blob's asset id.
    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }
}

/// *Update from source* for a placed file (import-formats.adoc, "Merge semantics"): replaces the
/// `content` register -- the file's blob, preview, bounding box and name, which describe one file
/// and are written together -- leaving the name, notes and transform alone, so a concurrent move
/// and an update both hold.  The caller stores the new blobs first, as for any import.  One
/// change, "Update from Source".
public struct UpdatePlacedFile: Command {
    public var node: OpID
    public var content: Wiretuner_Doc_V1_PlacedFileContent
    public var label: String { "Update from Source" }

    public init(_ node: OpID, content: Wiretuner_Doc_V1_PlacedFileContent) {
        self.node = node
        self.content = content
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.nodeKind(node) == .placedFile, Objects.editable([node], in: state) == [node] else { throw ObjectEditError.notAnObject(node) }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.placedFile.content = content
        builder.append(Ops.set(node, [PlacedFileFields.content], values: props))
    }
}
