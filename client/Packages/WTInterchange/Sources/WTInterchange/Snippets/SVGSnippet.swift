// The SVG and PNG snippets (collaboration/inspect.adoc, "Copying as code" and "Copying as PNG";
// COLLAB-036): the object alone through the export pipeline.  SVG is the SVG writer (IO-019) with
// its default options over a page tight around the object's drawing, so names become ids and text
// stays text; PNG is the bitmap rasterizer (IO-021) at the scale, background transparent, effects
// included.

import Foundation
import WTRender

/// The object as a standalone `<svg>`.
public enum SVGSnippet {
    public static func make(_ object: SnippetObject) -> String {
        let options = SVGOptions.defaults
        let scene = object.scene
        let flat = SVGExporter.flattener(options: options, scene: scene).flatten(scene.pages[0], scene: scene).page
        return SVGWriter(options: options).write(flat, scene: scene).text
    }
}

/// The object as a PNG at a scale.
public enum PNGSnippet {
    /// PNG bytes of the object at `scale` pixels per point, transparent where nothing draws.
    public static func make(_ object: SnippetObject, scale: Double) -> Data {
        let rasterizer = BitmapRasterizer(common: BitmapCommonOptions(scales: [scale], background: .transparent))
        let bitmap = rasterizer.render(object.page, scale: scale, bitsPerComponent: 8, alpha: true).bitmap
        // A rendered bitmap always encodes as PNG.
        return ImageEncoding.encode(bitmap.image, type: .png)!
    }

    /// The file name kbd:[Option]-click saves: the object's name with the scale appended
    /// (`Logo mark@2x.png`; no suffix at 1×).
    public static func fileName(_ object: SnippetObject, scale: Double) -> String {
        let base = (object.name?.isEmpty == false ? object.name! : "Object").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return base + (scale == 1 ? "" : "@\(Numbers.format(scale, places: 2))x") + ".png"
    }
}
