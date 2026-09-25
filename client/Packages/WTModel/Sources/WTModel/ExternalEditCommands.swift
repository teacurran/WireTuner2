import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

// IMG-019: the Edit With… round trip (external-editors.adoc): each save in the editor replaces the
// image's pixels keeping its placed width -- a returned image of other proportions recomputes its
// resolution and height -- and Cancel puts the original pixels and resolution back.

/// The pixel source of decoded pixels, as an import writes it.
public enum EditedImagePixels {
    public static func source(_ pixels: ImportedPixels) -> Wiretuner_Doc_V1_PixelSource {
        var source = Wiretuner_Doc_V1_PixelSource()
        source.blobSha256 = pixels.blob.sha256
        source.format = pixels.blob.uti
        source.pixelWidth = Int32(clamping: pixels.width)
        source.pixelHeight = Int32(clamping: pixels.height)
        source.mode = ImportMapping.mode(pixels.mode)
        source.bitsPerChannel = Int32(clamping: pixels.bitsPerChannel)
        source.hasAlpha_p = pixels.hasAlpha
        return source
    }
}

/// Replaces an image's pixels from its external editor: the placed width is kept and one
/// resolution for both axes follows from it (so the height follows the new proportions), unless
/// `dpi` restores a resolution (Cancel).  Labelled "Edit Image".
public struct ReplaceEditedImage: Command {
    public var node: OpID
    public var pixels: Wiretuner_Doc_V1_PixelSource
    public var dpi: (x: Double, y: Double)?
    public var label: String { "Edit Image" }

    public init(_ node: OpID, pixels: Wiretuner_Doc_V1_PixelSource, dpi: (x: Double, y: Double)? = nil) {
        self.node = node
        self.pixels = pixels
        self.dpi = dpi
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try ImageNodes.editable([node], in: state)
        try ImageNodes.check(pixels)
        let natural = ImageNodes.naturalRect(state.props(node).image)
        let resolution = natural.width > 0 ? Double(pixels.pixelWidth) / natural.width * 72 : 72
        let (dpiX, dpiY) = dpi ?? (resolution, resolution)
        try ImageNodes.check(dpi: dpiX)
        try ImageNodes.check(dpi: dpiY)
        builder.append(Ops.set(node, [ImageFields.pixels, ImageFields.dpiX, ImageFields.dpiY], values: ImageFields.values { image in
            image.pixels = pixels
            image.dpiX = dpiX
            image.dpiY = dpiY
        }))
    }
}
