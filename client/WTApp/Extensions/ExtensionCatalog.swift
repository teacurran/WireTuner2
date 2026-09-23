import Foundation

/// Every extension of extensions.adoc: the Extensions menu's operations in the table's order
/// (submenu = category), then the tool extensions of the Extension Tools toolbar, which live in
/// the Tools panel flyouts too and are grouped for Manage Extensions under the category their
/// operation shares (Distort, Chart) or under *Tools*.  Operations are stubs until their epic
/// replaces the descriptor (`ExtensionRegistry.replace`).
enum ExtensionCatalog {
    enum Category {
        static let animate = "Animate"
        static let chart = "Chart"
        static let cleanup = "Cleanup"
        static let colors = "Colors"
        static let create = "Create"
        static let delete = "Delete"
        static let distort = "Distort"
        static let pathOperations = "Path Operations"
        static let other = ExtensionRegistry.otherCategory
        static let tools = "Tools"
    }

    private static func op(_ id: String, _ title: String, _ category: String, _ symbol: String, _ help: String, toolbar: Bool = false) -> ExtensionDescriptor {
        ExtensionDescriptor(id: id, title: title, category: category, toolbars: toolbar ? [.operations] : [], symbolName: symbol, helpSlug: help)
    }

    private static func tool(_ id: ToolID, _ title: String, _ category: String, _ symbol: String, _ help: String) -> ExtensionDescriptor {
        ExtensionDescriptor(id: "tool.\(id.rawValue)", title: title, category: category, kind: .tool(id), toolbars: [.tools], symbolName: symbol, helpSlug: help)
    }

    static let operations: [ExtensionDescriptor] = [
        op("releaseToLayers", "Release to Layers", Category.animate, "square.3.layers.3d", "animation", toolbar: true),
        op("pictograph", "Pictograph…", Category.chart, "chart.bar.doc.horizontal", "charts"),
        op("removePictograph", "Remove Pictograph", Category.chart, "chart.bar.xaxis", "charts"),
        op("correctDirection", "Correct Direction", Category.cleanup, "arrow.triangle.2.circlepath", "editing-paths", toolbar: true),
        op("removeOverlap", "Remove Overlap", Category.cleanup, "square.on.square.dashed", "editing-paths", toolbar: true),
        op("reverseDirection", "Reverse Direction", Category.cleanup, "arrow.uturn.backward", "editing-paths", toolbar: true),
        op("simplify", "Simplify…", Category.cleanup, "scribble", "editing-paths", toolbar: true),
        op("colorControl", "Color Control…", Category.colors, "slider.horizontal.3", "editing-colors"),
        op("convertToGrayscale", "Convert to Grayscale", Category.colors, "circle.lefthalf.filled", "editing-colors"),
        op("darkenColors", "Darken Colors", Category.colors, "moon", "editing-colors"),
        op("desaturateColors", "Desaturate Colors", Category.colors, "drop", "editing-colors"),
        op("importRGBColorTable", "Import RGB Color Table…", Category.colors, "tablecells", "color-tables"),
        op("lightenColors", "Lighten Colors", Category.colors, "sun.max", "editing-colors"),
        op("nameAllColors", "Name All Colors", Category.colors, "tag", "editing-colors"),
        op("randomizeNamedColors", "Randomize Named Colors", Category.colors, "shuffle", "editing-colors"),
        op("saturateColors", "Saturate Colors", Category.colors, "drop.fill", "editing-colors"),
        op("sortColorListByName", "Sort Color List by Name", Category.colors, "textformat.abc", "color-tables"),
        op("blend", "Blend", Category.create, "square.on.circle", "blends", toolbar: true),
        op("emboss", "Emboss…", Category.create, "square.3.layers.3d.down.right", "path-effects", toolbar: true),
        op("fractalize", "Fractalize", Category.create, "snowflake", "path-effects", toolbar: true),
        op("trap", "Trap…", Category.create, "square.dashed.inset.filled", "printing", toolbar: true),
        op("deleteEmptyTextBlocks", "Empty Text Blocks", Category.delete, "text.badge.xmark", "editing-text"),
        op("deleteUnusedNamedColors", "Unused Named Colors", Category.delete, "paintpalette", "swatches"),
        op("addPoints", "Add Points", Category.distort, "plus.circle", "path-effects", toolbar: true),
        op("bend", "Bend…", Category.distort, "arrow.uturn.right", "path-effects"),
        op("fisheyeLens", "Fisheye Lens…", Category.distort, "eye", "path-effects"),
        op("roughen", "Roughen…", Category.distort, "waveform.path", "path-effects"),
        op("smudge", "Smudge…", Category.distort, "hand.point.up.left", "path-effects"),
        op("rotation3D", "3D Rotation…", Category.distort, "rotate.3d", "path-effects"),
        op("union", "Union", Category.pathOperations, "square.on.square", "combining-paths", toolbar: true),
        op("divide", "Divide", Category.pathOperations, "square.split.2x2", "combining-paths", toolbar: true),
        op("intersect", "Intersect", Category.pathOperations, "square.on.square.intersection.dashed", "combining-paths", toolbar: true),
        op("punch", "Punch", Category.pathOperations, "square.on.square.squareshape.controlhandles", "combining-paths", toolbar: true),
        op("crop", "Crop", Category.pathOperations, "crop", "combining-paths", toolbar: true),
        op("transparency", "Transparency…", Category.pathOperations, "square.2.layers.3d.top.filled", "combining-paths", toolbar: true),
        op("expandStroke", "Expand Stroke…", Category.pathOperations, "lineweight", "expand-stroke", toolbar: true),
        op("insetPath", "Inset Path…", Category.pathOperations, "square.inset.filled", "inset-path", toolbar: true),
        op("fileInfo", "File Info…", Category.other, "info.circle", "file-info"),
    ]

    static let tools: [ExtensionDescriptor] = [
        tool("mirror", "Mirror", Category.distort, "arrow.left.and.right.righttriangle.left.righttriangle.right", "path-effects"),
        tool("roughen", "Roughen", Category.distort, "waveform.path", "path-effects"),
        tool("bend", "Bend", Category.distort, "arrow.uturn.right", "path-effects"),
        tool("fisheyeLens", "Fisheye Lens", Category.distort, "eye", "path-effects"),
        tool("smudge", "Smudge", Category.distort, "hand.point.up.left", "path-effects"),
        tool("shadow", "Shadow", Category.distort, "shadow", "path-effects"),
        tool("rotation3D", "3D Rotation", Category.distort, "rotate.3d", "path-effects"),
        tool("graphicHose", "Graphic Hose", Category.tools, "sparkles", "graphic-hose"),
        tool("chart", "Chart", Category.chart, "chart.bar", "charts"),
        tool("spiral", "Spiral", Category.tools, "hurricane", "spirals-arcs"),
        tool("arc", "Arc", Category.tools, "rainbow", "spirals-arcs"),
        tool("eyedropper", "Eyedropper", Category.tools, "eyedropper", "applying-color"),
        tool("extrude", "Extrude", Category.tools, "cube", "extrude"),
        tool("blend", "Blend", Category.tools, "square.on.circle", "blends"),
        tool("perspective", "Perspective", Category.tools, "perspective", "perspective"),
        tool("connector", "Connector", Category.tools, "point.3.connected.trianglepath.dotted", "connectors"),
        tool("action", "Action", Category.tools, "hand.tap", "interactivity"),
        tool("outputArea", "Output Area", Category.tools, "crop", "output-area"),
        tool("eraser", "Eraser", Category.tools, "eraser", "editing-paths"),
    ]

    static var all: [ExtensionDescriptor] { operations + tools }

    /// The Extension Operations toolbar's order (extensions.adoc), which differs from the menu's.
    static let operationsToolbarOrder = [
        "union", "divide", "intersect", "punch", "crop", "transparency", "expandStroke", "insetPath", "addPoints",
        "correctDirection", "reverseDirection", "removeOverlap", "simplify", "blend", "emboss", "fractalize", "trap", "releaseToLayers",
    ]

    /// A toolbar's default extensions by id.
    static func toolbarOrder(_ toolbar: ExtensionToolbar) -> [String] {
        switch toolbar {
        case .operations: operationsToolbarOrder
        case .tools: tools.map(\.id)
        }
    }
}
