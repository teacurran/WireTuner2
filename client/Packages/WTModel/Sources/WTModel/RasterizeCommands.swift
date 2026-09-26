import WTCRDT
import WTGeometry
import WTInterchange
import WTProto

// IMG-020 and IMG-024: the document halves of *Optimize Image* and *Rasterize*
// (imported/external-editors.adoc and imported/rasterizing.adoc, "Data model").  WTInterchange's
// `ImageOptimizer` and `SelectionRasterizer` make the pixels; these write them as one change each.

extension ImportedPixels {
    /// The stored `PixelSource` of these pixels.
    public var pixelSource: Wiretuner_Doc_V1_PixelSource {
        var pixels = Wiretuner_Doc_V1_PixelSource()
        pixels.blobSha256 = blob.sha256
        pixels.format = blob.uti
        pixels.pixelWidth = Int32(clamping: width)
        pixels.pixelHeight = Int32(clamping: height)
        pixels.mode = ImportMapping.mode(mode)
        pixels.bitsPerChannel = Int32(clamping: bitsPerChannel)
        pixels.hasAlpha_p = hasAlpha
        return pixels
    }
}

/// btn:[Optimize]: each image's `pixels` replaced by its optimized blob, `dpi_x`/`dpi_y`
/// recomputed so the placed size stays (`ReplaceImagePixels` per image), all in one change.  A
/// grayscale result leaves `tint`, `transparent_background` and `ramp` as they are -- the
/// read-time rule starts applying them.  "Optimize <name>", "Optimize (3 images)".
public struct OptimizeImages: Command {
    public var results: [(node: OpID, pixels: ImportedPixels)]
    public var label: String

    public init(_ results: [(node: OpID, pixels: ImportedPixels)], names: [String] = []) {
        self.results = results
        label = results.count == 1 ? "Optimize \(names.first ?? "Image")" : ImageNodes.label("Optimize", count: results.count)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (node, pixels) in results {
            try ReplaceImagePixels(node, pixels: pixels.pixelSource).execute(&builder, state: state)
        }
    }
}

/// btn:[Rasterize]: an image of the selection's pixels placed over the selection's rendered
/// bounds -- directly above the topmost selected object, in its parent -- named "Rasterized
/// <first object's name>" with the rasterizing resolution as its stored resolution, then, unless
/// *Keep originals*, `SetDeleted` for every selected object.  One change, so Undo restores the
/// originals (the same ids) and removes the image.  "Rasterize 3 objects".
public struct RasterizeObjects: Command {
    public var nodes: [OpID]
    public var image: RasterizedImage
    public var keepOriginals: Bool
    public var label: String { nodes.count == 1 ? "Rasterize 1 object" : "Rasterize \(nodes.count) objects" }

    public init(_ nodes: [OpID], image: RasterizedImage, keepOriginals: Bool = false) {
        self.nodes = nodes
        self.image = image
        self.keepOriginals = keepOriginals
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !nodes.isEmpty else { throw ObjectEditError.invalidValue("nodes") }
        for node in nodes where !Objects.editable([node], in: state).contains(node) {
            throw ObjectEditError.notAnObject(node)
        }
        // Every node is a live object, so it has a parent and a stacking place.
        let top = Objects.stackingOrder(nodes, in: state).last!
        let parent = Objects.parent(of: top, in: state)!
        let pixels = image.pixels.pixelSource
        try ImageNodes.check(pixels)
        try ImageNodes.check(dpi: image.ppi)
        let position = try Arranging.keys(next: top, above: true, count: 1, in: state)[0]
        // The natural frame (0, 0, size) moved onto the bounds, in the parent's space.
        let toLocal = Objects.pasteboardTransform(ofSpace: parent, in: state).inverse
        let transform = AffineTransform.translation(x: image.bounds.minX, y: image.bounds.minY).concatenating(toLocal)
        let name = String("Rasterized \(state.displayName(of: nodes[0]))".prefix(256))
        let props = ImageFields.values { value in
            value.common.name = name
            if !transform.isIdentity { value.common.transform = PathEditing.proto(transform) }
            value.pixels = pixels
            value.sourceName = name
            value.dpiX = image.ppi
            value.dpiY = image.ppi
            value.displayAlpha = true
        }
        builder.append(Ops.create(parent: parent, position: position, props: props))
        guard !keepOriginals else { return }
        for node in nodes {
            builder.append(Ops.setDeleted(node))
        }
    }
}
