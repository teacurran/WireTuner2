import WTGeometry
@testable import WTRender

/// Reference cases for the page furniture (DOC-009) and the grid (DOC-016): goldens, the
/// bitmap/PDF gate and Metal parity run over them with the rest of `ReferenceCorpus`.
enum PageCorpus {
    typealias C = ReferenceCorpus

    /// Cases drawing one-device-pixel lines (outlines, the bleed line).
    static let hairlineCases: Set<String> = ["pageFurniture", "pageGrid"]

    static let pages = [
        PageFrame(rect: Rect(x: 10, y: 12, width: 44, height: 64), bleed: 4, presence: [FeatureCorpus.red, FeatureCorpus.blue]),
        PageFrame(rect: Rect(x: 72, y: 12, width: 44, height: 64), isActive: true),
    ]

    static let style = PageStyle(pasteboard: Rect(x: 0, y: 0, width: 128, height: 96), presenceDotDiameter: 5)

    static let grid = GridRendering.item(GridSpec(size: 8, origin: Point(x: 10.5, y: 12.5)), in: Rect(x: 0, y: 0, width: 128, height: 96), zoom: 1)!

    static let cases: [ReferenceCase] = [
        ReferenceCase(name: "pageFurniture", list: C.list([PageRendering.item(pages, style: style)])),
        ReferenceCase(name: "pageFurniturePrint", list: C.list([PageRendering.item(pages, style: style, output: .print, grid: [grid])])),
        ReferenceCase(name: "pageGrid", list: C.list([PageRendering.item(pages, style: style, grid: [grid])])),
    ]
}
