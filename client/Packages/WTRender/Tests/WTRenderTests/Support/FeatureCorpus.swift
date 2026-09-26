// The derived-drawing cases: layer rendering rules (LIB-005), symbol instances with overrides
// and placeholders (LIB-010, LIB-026), every chart type and its options (DRAW-032), connector
// routes (DRAW-035/037) and barcodes (DATA-018).  Each joins `ReferenceCorpus.cases`, so it
// has goldens at 1× and 4× and runs through REND-007's Metal/Core Graphics parity.

import WTGeometry
import CoreGraphics
import Foundation
@testable import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

enum FeatureCorpus {
    typealias C = ReferenceCorpus

    static let blue = Color(red: 0.1, green: 0.3, blue: 0.85)
    static let red = Color(red: 0.85, green: 0.15, blue: 0.1)
    static let green = Color(red: 0.1, green: 0.6, blue: 0.25)
    static let orange = Color(red: 0.95, green: 0.55, blue: 0.1)

    static func id(_ counter: UInt64, _ replica: UInt64 = 1) -> NodeID {
        NodeID(counter: counter, replica: replica)
    }

    /// Cases drawing one-device-pixel lines in Preview (keyline layers, guides).
    static let hairlineCases: Set<String> = ["layerRules"]

    static let labels = CoreTextLabels(font: GlyphFont(postScriptName: "Helvetica", size: 7))

    static let cases: [ReferenceCase] = [
        ReferenceCase(name: "layerRules", list: layers(purpose: .screen(guideColor: Color(red: 0.2, green: 0.8, blue: 0.9)))),
        ReferenceCase(name: "layerRulesFast", list: layers(purpose: .screen(guideColor: Color(red: 0.2, green: 0.8, blue: 0.9))), viewMode: .fastPreview),
        ReferenceCase(name: "layerRulesOutput", list: layers(purpose: .output(includeHidden: true))),
        // The placeholder's hatching is half-point strokes under a clip, whose edge pixels PDF
        // rasterizes up to 37/255 apart from the bitmap; goldens and parity hold it.
        ReferenceCase(name: "symbolInstances", list: instances, comparesPDF: false),
        ReferenceCase(name: "symbolOverrides", list: overrides),
        ReferenceCase(name: "symbolTextOverrides", list: textOverrides),
        ReferenceCase(name: "chartGroupedColumn", list: chart(.groupedColumn, options: ChartOptions(dataNumbers: true, dropShadow: true, gridlinesX: true)), viewSize: chartView),
        ReferenceCase(name: "chartStackedColumn", list: chart(.stackedColumn, options: ChartOptions(columnWidth: 60, legendsAcrossTop: true, axisDisplay: .both, gridlinesY: true)), viewSize: chartView),
        ReferenceCase(name: "chartLine", list: chart(.line, options: ChartOptions(markers: .diamond, dataNumbers: true), yAxis: ChartAxis(manual: ChartAxisRange(minimum: 0, maximum: 12, between: 3), major: .across, minor: .inside, minorCount: 2, prefix: "$")), viewSize: chartView),
        ReferenceCase(name: "chartMarkers", list: chart(.line, options: ChartOptions(markers: .circle, axisDisplay: .right), series: 3, yAxis: ChartAxis(major: .inside)), viewSize: chartView),
        ReferenceCase(name: "chartPie", list: chart(.pie, options: ChartOptions(pieSeparation: 12, dataNumbers: true, dropShadow: true)), viewSize: chartView),
        ReferenceCase(name: "chartArea", list: chart(.area, options: ChartOptions(dropShadow: true, gridlinesX: true)), viewSize: chartView),
        ReferenceCase(name: "chartScatter", list: chart(.scatter, options: ChartOptions(markers: .triangle, gridlinesY: true), series: 4, xAxis: ChartAxis(major: .outside, suffix: "%")), viewSize: chartView),
        ReferenceCase(name: "chartPictographs", list: pictographs, viewSize: chartView),
        ReferenceCase(name: "connectorRoutes", list: connectors),
        ReferenceCase(name: "barcodes", list: barcodes, viewSize: Size(width: 160, height: 96)),
        ReferenceCase(name: "placedFiles", list: placedFiles),
    ]

    // MARK: Placed files

    /// IMG-011's gray boxes (no renderer store, so a preview-bearing file draws its box too):
    /// a file without a preview, a rotated file whose preview is not cached with a name longer
    /// than its box, and a zero-area box read as one inch square.
    static var placedFiles: DisplayList {
        C.list([
            PlacedFileDrawing.item(PlacedFile(bounds: Rect(x: 0, y: 0, width: 56, height: 40), name: "logo.eps", transform: .translation(x: 4, y: 4))),
            PlacedFileDrawing.item(PlacedFile(bounds: Rect(x: 0, y: 0, width: 44, height: 30), previewAssetID: "cafe", previewWidth: 88, previewHeight: 60, name: "a long file name.eps",
                                              transform: AffineTransform.rotation(radians: .pi / 12).concatenating(.translation(x: 70, y: 6)))),
            PlacedFileDrawing.item(PlacedFile(bounds: Rect(x: 10, y: 0, width: 0, height: 20), name: "flat.eps", transform: AffineTransform.scale(x: 0.5, y: 0.5).concatenating(.translation(x: 0, y: 50)))),
        ])
    }

    // MARK: Layers

    /// A background layer (dimmed), a printing layer, a keyline layer with its own highlight,
    /// a hidden layer and the Guides layer, over page furniture.
    static func layers(purpose: LayerScene.Purpose) -> DisplayList {
        func square(_ x: Double, _ y: Double, _ color: Color) -> DisplayItem {
            C.path(DisplayPath(rect: Rect(x: x, y: y, width: 36, height: 30)), [C.fill(color), C.stroke(.black, width: 2)])
        }
        var guide = DisplayPath()
        guide.move(to: Point(x: 0, y: 70))
        guide.addLine(to: Point(x: 128, y: 70))
        let content = [
            LayerContent(layer: LayerRendering(id: id(1), printing: false, highlight: blue), items: [(square(6, 6, orange), id(11)), (square(24, 20, blue), id(12))]),
            LayerContent(layer: LayerRendering(id: id(2), highlight: red), items: [(square(50, 10, green), id(21))]),
            LayerContent(layer: LayerRendering(id: id(3), keyline: true, highlight: red), items: [(square(80, 30, blue), id(31)), (.text(TextRunItem(text: "K", glyphRun: C.makeGlyphRun("K", font: GlyphFont(postScriptName: "Helvetica-Bold", size: 20), at: Point(x: 86, y: 86)), origin: Point(x: 86, y: 86), color: red)), id(32))]),
            LayerContent(layer: LayerRendering(id: id(4)), visible: false, items: [(square(10, 56, red), id(41))]),
            LayerContent(layer: LayerRendering(id: id(5), isGuides: true), items: [(C.path(guide, [C.stroke(.black, width: 0)]), id(51))]),
        ]
        let furniture = C.path(DisplayPath(rect: Rect(x: 2, y: 2, width: 124, height: 92)), [C.fill(Color(white: 0.97))])
        return LayerScene.build(canvas: "reference", layers: content, purpose: purpose, background: [furniture])
    }

    // MARK: Symbols

    static let star = SymbolArtwork(symbol: id(100), name: "Star", version: 1, origin: Point(x: 10, y: 10), nodes: [
        SymbolNode(id: id(101), content: .item(C.path(starPath(center: Point(x: 10, y: 10), radius: 10), [C.fill(orange), C.stroke(.black, width: 1)]))),
        SymbolNode(id: id(102), content: .group(GroupItem(children: [], opacity: 0.8), members: [
            SymbolNode(id: id(103), content: .item(C.path(DisplayPath(ellipseIn: Rect(x: 6, y: 6, width: 8, height: 8)), [C.fill(blue)]))),
        ])),
    ])

    static let badge = SymbolArtwork(symbol: id(110), name: "Badge", version: 1, nodes: [
        SymbolNode(id: id(111), content: .item(C.path(DisplayPath(rect: Rect(x: 0, y: 0, width: 30, height: 24)), [C.fill(Color(white: 0.85)), C.stroke(green, width: 1.5)]))),
        SymbolNode(id: id(112), content: .instance(SymbolInstance(symbol: id(100), transform: .translation(x: 15, y: 12)))),
        SymbolNode(id: id(113), content: .item(.image(ImageItem(assetID: "badge-art", rect: Rect(x: 2, y: 2, width: 8, height: 6))))),
        SymbolNode(id: id(114), content: .item(.text(TextRunItem(text: "B", glyphRun: C.makeGlyphRun("B", font: GlyphFont(postScriptName: "Helvetica-Bold", size: 9), at: Point(x: 22, y: 21)), origin: Point(x: 22, y: 21), color: red)))),
    ])

    static let library = SymbolLibrary([star, badge])

    static func starPath(center: Point, radius: Double) -> DisplayPath {
        DisplayPath(polygon: (0..<10).map { index in
            let angle = Double(index) * .pi / 5 - .pi / 2
            let r = index.isMultiple(of: 2) ? radius : radius * 0.45
            return Point(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        })
    }

    /// Plain, rotated and scaled instances, a nested instance, and a missing symbol's
    /// placeholder.
    static let instances: DisplayList = {
        let renderer = SymbolRenderer(typesetter: labels)
        return C.list([
            renderer.item(for: SymbolInstance(symbol: id(100), transform: .translation(x: 16, y: 16)), in: library),
            renderer.item(for: SymbolInstance(symbol: id(100), transform: AffineTransform.scale(1.6).concatenating(.rotation(degrees: 20)).concatenating(.translation(x: 52, y: 22))), in: library),
            renderer.item(for: SymbolInstance(symbol: id(110), transform: .translation(x: 80, y: 8)), in: library),
            renderer.item(for: SymbolInstance(symbol: id(110), transform: AffineTransform.rotation(degrees: -12).concatenating(.translation(x: 10, y: 52))), in: library),
            renderer.item(for: SymbolInstance(symbol: id(199), transform: .translation(x: 90, y: 66), placeholderName: "Gone", placeholderRect: Rect(x: -24, y: -18, width: 48, height: 36)), in: library),
        ])
    }()

    /// One instance per override kind: fill, stroke, hidden (a subtree inside a group), image,
    /// text.
    static let overrides: DisplayList = {
        let renderer = SymbolRenderer(typesetter: labels)
        let text = TextRunItem(text: "Z", glyphRun: C.makeGlyphRun("Z", font: GlyphFont(postScriptName: "Helvetica-Bold", size: 9), at: Point(x: 21, y: 21)), origin: Point(x: 21, y: 21), color: blue)
        let placed: [(SymbolInstance, Double, Double)] = [
            (SymbolInstance(symbol: id(110), overrides: [.fill(id(111), Color(red: 1, green: 0.9, blue: 0.6))]), 4, 6),
            (SymbolInstance(symbol: id(110), overrides: [.stroke(id(111), red)]), 44, 6),
            (SymbolInstance(symbol: id(100), overrides: [.hidden(id(103)), .fill(id(101), green)]), 94, 16),
            (SymbolInstance(symbol: id(110), overrides: [.image(id(113), assetID: "other-art")]), 4, 50),
            (SymbolInstance(symbol: id(110), overrides: [.text(id(114), [.text(text)])]), 44, 50),
        ]
        return C.list(placed.map { instance, x, y in
            var placedInstance = instance
            placedInstance.transform = .translation(x: x, y: y)
            return renderer.item(for: placedInstance, in: library)
        })
    }()

    // MARK: Text overrides

    /// One laid-out run as WTModel supplies it: `text` in `font` from `origin` (symbol space).
    static func run(_ text: String, _ font: GlyphFont, at origin: Point, _ color: Color) -> DisplayItem {
        let glyphs = C.makeGlyphRun(text, font: font, at: origin)
        return .text(TextRunItem(text: text, origin: origin, bounds: glyphs.inkBounds ?? Rect(origin, origin), color: color, glyphRun: glyphs))
    }

    static let regular = GlyphFont(postScriptName: "Helvetica", size: 8)
    static let bold = GlyphFont(postScriptName: "Helvetica-Bold", size: 8)

    /// A card: a frame and a text block "Buy now" (two runs, one bold) on one line.
    static let card = SymbolArtwork(symbol: id(120), name: "Card", version: 1, origin: Point(x: 22, y: 14), nodes: [
        SymbolNode(id: id(121), content: .item(C.path(DisplayPath(rect: Rect(x: 0, y: 0, width: 44, height: 28)), [C.fill(Color(white: 0.92)), C.stroke(blue, width: 1)]))),
        SymbolNode(id: id(122), content: .item(.group(GroupItem(children: [run("Buy", bold, at: Point(x: 4, y: 12), .black), run(" now", regular, at: Point(x: 20, y: 12), .black)])))),
    ])

    /// A host symbol holding a card instance whose text is overridden (overrides of a nested
    /// instance travel with it).
    static let cardHost = SymbolArtwork(symbol: id(130), name: "Host", version: 1, nodes: [
        SymbolNode(id: id(131), content: .item(C.path(DisplayPath(ellipseIn: Rect(x: 0, y: 0, width: 56, height: 36)), [C.fill(Color(red: 0.9, green: 0.95, blue: 0.85))]))),
        SymbolNode(id: id(132), content: .instance(SymbolInstance(symbol: id(120), transform: .translation(x: 28, y: 18), overrides: [.text(id(122), cardText)]))),
    ])

    /// The override's layout: "Sale ends" in two colours over two lines, the master block's
    /// place.
    static let cardText: [DisplayItem] = [
        .group(GroupItem(children: [
            run("Sale", bold, at: Point(x: 4, y: 11), red),
            run(" ends", regular, at: Point(x: 22, y: 11), blue),
            run("today", regular, at: Point(x: 4, y: 21), green),
        ])),
    ]

    static let textLibrary = SymbolLibrary([card, cardHost])

    /// The master's words; the override laid out in their place; the override on a rotated and
    /// scaled instance; and a nested instance carrying its override inside a host.
    static let textOverrides: DisplayList = {
        let renderer = SymbolRenderer(typesetter: labels)
        return C.list([
            renderer.item(for: SymbolInstance(symbol: id(120), transform: .translation(x: 26, y: 18)), in: textLibrary),
            renderer.item(for: SymbolInstance(symbol: id(120), transform: .translation(x: 76, y: 18), overrides: [.text(id(122), cardText)]), in: textLibrary),
            renderer.item(for: SymbolInstance(symbol: id(120), transform: AffineTransform.scale(1.3).concatenating(.rotation(degrees: -15)).concatenating(.translation(x: 38, y: 64)),
                                              overrides: [.text(id(122), cardText), .fill(id(121), Color(red: 1, green: 0.95, blue: 0.8))]), in: textLibrary),
            renderer.item(for: SymbolInstance(symbol: id(130), transform: .translation(x: 66, y: 52)), in: textLibrary),
        ])
    }()

    // MARK: Charts

    static let chartView = Size(width: 200, height: 130)

    static func table(series: Int, categories: Int = 3) -> ChartTable {
        let names = ["North", "South", "East", "West"]
        let values: [[Double]] = [[4, 7, 2, 5], [6, 3, 5, 8], [9, 5, 4, 2]]
        return ChartTable(
            series: (0..<series).map { ChartKey(id: id(200 + UInt64($0)), label: names[$0]) },
            categories: (0..<categories).map { ChartKey(id: id(300 + UInt64($0)), label: "Q\($0 + 1)") },
            values: (0..<categories).map { Array(values[$0].prefix(series)) }
        )
    }

    static func chart(_ type: ChartType, options: ChartOptions, series: Int = 2, xAxis: ChartAxis = ChartAxis(), yAxis: ChartAxis = ChartAxis()) -> DisplayList {
        let spec = ChartSpec(chart: id(400), type: type, size: Size(width: 110, height: 70), table: table(series: series), options: options, xAxis: xAxis, yAxis: yAxis, decimalPrecision: 0)
        return C.list([ChartLayout(spec: spec, typesetter: labels).displayItem(transform: .translation(x: 24, y: 30))])
    }

    /// Repeating and stretched pictographs, an element style and a series style.
    static let pictographs: DisplayList = {
        let figure: [DisplayItem] = [
            C.path(DisplayPath(ellipseIn: Rect(x: 3, y: 0, width: 4, height: 4)), [C.fill(red)]),
            C.path(DisplayPath(rect: Rect(x: 2, y: 4, width: 6, height: 6)), [C.fill(blue)]),
        ]
        var spec = ChartSpec(chart: id(401), type: .groupedColumn, size: Size(width: 110, height: 70), table: table(series: 2), decimalPrecision: 0)
        spec.seriesStyles[id(200)] = ChartStyle(pictograph: figure, repeating: true)
        spec.seriesStyles[id(201)] = ChartStyle(pictograph: figure)
        spec.elementStyles[ChartElementKey(series: id(201), index: id(302))] = ChartStyle(appearance: Appearance([C.fill(green)]), transform: .rotation(degrees: 10))
        return C.list([ChartLayout(spec: spec, typesetter: labels).displayItem(transform: .translation(x: 24, y: 30))])
    }()

    // MARK: Connectors

    static let connectors: DisplayList = {
        let boxes: [(NodeID, Rect)] = [
            (id(500), Rect(x: 8, y: 8, width: 26, height: 18)),
            (id(501), Rect(x: 90, y: 60, width: 30, height: 20)),
            (id(502), Rect(x: 92, y: 6, width: 26, height: 16)),
        ]
        var builder = DisplayListBuilder(canvas: "reference")
        for (node, rect) in boxes {
            builder.add(C.path(DisplayPath(rect: rect), [C.fill(Color(white: 0.9)), C.stroke(.black, width: 1)]), node: node)
        }
        let nodes = builder.build()
        let arrow = Appearance([.stroke(StrokePaint(paint: .solid(blue), style: StrokeStyle(width: 1.5, join: .round), endArrowhead: .triangle))])
        let specs = [
            ConnectorSpec(id: id(510), start: ConnectorEnd(node: id(500), side: .right, point: .zero), end: ConnectorEnd(node: id(501), side: .left, point: .zero), appearance: arrow),
            ConnectorSpec(id: id(511), start: ConnectorEnd(node: id(500), side: .bottom, point: .zero), end: ConnectorEnd(node: id(501), side: .bottom, point: .zero), runOffsets: [], appearance: Appearance([C.stroke(red, width: 1, dash: [3, 2])])),
            ConnectorSpec(id: id(512), start: ConnectorEnd(node: id(502), side: .left, point: .zero), end: ConnectorEnd(point: Point(x: 50, y: 50)), routing: .curved, appearance: arrow),
            ConnectorSpec(id: id(513), start: ConnectorEnd(node: id(502), side: .bottom, point: .zero), end: ConnectorEnd(node: id(501), side: .top, point: .zero), routing: .straight, appearance: Appearance([C.stroke(green, width: 2)])),
        ]
        var items = nodes.items
        var ids = nodes.nodeIDs
        for spec in specs {
            items.append(ConnectorRendering.item(spec, in: nodes))
            ids.append(spec.id)
        }
        return DisplayList(canvas: "reference", items: items, nodeIDs: ids)
    }()

    // MARK: Barcodes

    static let barcodes = C.list([
        BarcodeRendering.item(BarcodeSpec(symbology: .qr, value: "https://wiretuner.app", errorCorrection: .low, quietZone: 2, transform: .translation(x: 4, y: 4))),
        BarcodeRendering.item(BarcodeSpec(symbology: .code128, value: "WT-2026", quietZone: 2, showText: true, paint: .solid(blue), transform: AffineTransform.scale(x: 0.8, y: 1).concatenating(.translation(x: 42, y: 10)))),
        BarcodeRendering.item(BarcodeSpec(symbology: .code128, value: "é", transform: .translation(x: 42, y: 56))),
    ])
}
