import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

/// PRINT-003, PRINT-005, PRINT-006, PRINT-008: the print plan -- which sheets a job has, in what
/// order, where each page lands on the paper, and the marks and labels around it.
@Suite struct PrintPlanTests {
    static let inch = 72.0
    static let spotA = NodeID(counter: 50, replica: 1)
    static let spotB = NodeID(counter: 51, replica: 1)

    static func page(number: Int?, rect: Rect, items: [DisplayItem] = [], nodes: [NodeID?] = [], nested: [[Int]: NodeID] = [:]) -> ExportPage {
        ExportPage(bounds: rect, displayList: DisplayList(canvas: "print", items: items, nodeIDs: nodes), nestedNodeIDs: nested, number: number)
    }

    static func request(_ pages: [ExportPage], options: PrintOptions = PrintOptions(), paper: PrintPaper = .letter, range: ClosedRange<Int>? = nil,
                        selection: Set<NodeID>? = nil, zero: [Int: Point] = [:], source: PrintRequest.Source = .pages) -> PrintRequest {
        PrintRequest(scene: ExportScene(name: "Poster", pages: pages), source: source, options: options, paper: paper, pageRange: range,
                     selection: selection, zeroPoints: zero, date: Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(identifier: "UTC")!)
    }

    static func letterPages(_ count: Int) -> [ExportPage] {
        (0..<count).map { page(number: $0 + 1, rect: Rect(x: Double($0) * 700, y: 0, width: 612, height: 792)) }
    }

    static let twoSpots: [PrintPlate] = PrintPlate.process + [PrintPlate(ink: .spot(spotA), name: "PANTONE 185 C"), PrintPlate(ink: .spot(spotB), name: "Gold")]

    // MARK: Pages

    @Test func pagesAndRangesChooseTheSheets() {
        let pages = Self.letterPages(3)
        #expect(PrintPlan(Self.request(pages)).count == 3)
        let two = PrintPlan(Self.request(pages, range: 2...2))
        #expect(two.count == 1 && two.sheets[0].pageNumber == 2 && two.sheets[0].name == "Page 2")
        // The range does not apply to the output area.
        let area = PrintPlan(Self.request([Self.page(number: nil, rect: Rect(x: 0, y: 0, width: 100, height: 100))], range: 2...2, source: .outputArea(pageOutlines: [])))
        #expect(area.count == 1 && area.sheets[0].name == "Output area")
    }

    @Test func selectedObjectsOnlyKeepsPositions() throws {
        let a = NodeID(counter: 1, replica: 1), b = NodeID(counter: 2, replica: 1), layer = NodeID(counter: 9, replica: 1)
        let groupID = NodeID(counter: 3, replica: 1), inner = NodeID(counter: 4, replica: 1), other = NodeID(counter: 5, replica: 1)
        let square = { (x: Double) in Corpus.path(Corpus.rect(x, 10, 20, 20), [Corpus.fill(.solid(Corpus.red))]) }
        let group = DisplayItem.group(GroupItem(children: [square(100), square(130)]))
        let layerGroup = DisplayItem.group(GroupItem(children: [square(10), square(40), group]))
        let loose = square(70)
        let page = Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 200, height: 100), items: [layerGroup, loose], nodes: [layer, nil],
                             nested: [[0, 0]: a, [0, 1]: b, [0, 2]: groupID, [0, 2, 0]: inner, [0, 2, 1]: other])
        let plan = PrintPlan(Self.request([page], selection: [b, inner]))
        let kept = plan.pages[0]
        #expect(kept.displayList.count == 1 && kept.displayList.nodeIDs == [layer])
        guard case .group(let layerKept) = kept.displayList.items[0], case .group(let groupKept) = layerKept.children[1] else {
            Issue.record("the layer and the group stay groups")
            return
        }
        #expect(layerKept.children.count == 2 && groupKept.children.count == 1)
        #expect(kept.nestedNodeIDs == [[0, 0]: b, [0, 1]: groupID, [0, 1, 0]: inner])
        // Positions are kept: the kept square is where it was.
        #expect(layerKept.children[0].bounds == square(40).bounds)
        // Selecting a group keeps all of it; selecting nothing on the page prints it empty.
        let whole = PrintPlan(Self.request([page], selection: [groupID])).pages[0]
        #expect(whole.nestedNodeIDs[[0, 0, 1]] == other)
        #expect(PrintPlan(Self.request([page], selection: [])).pages[0].displayList.isEmpty)
    }

    // MARK: Scale

    @Test func fitOnPaperKeepsProportions() throws {
        let tabloid = Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 792, height: 1224))
        let plan = PrintPlan(Self.request([tabloid], options: PrintOptions(scaleMode: .fit, tile: .automatic)))
        #expect(plan.count == 1 && plan.sheets[0].tile == nil)
        let scale = plan.scales[0]
        #expect(scale.x == scale.y && abs(scale.x - 756.0 / 1224) < 1e-9)
        let trim = plan.sheets[0].trim
        #expect(abs(trim.width / trim.height - 792.0 / 1224) < 1e-9)
        #expect(PrintPaper.letter.imageable.contains(trim))
        // Marks and bleed are included in what has to fit.
        let marked = PrintPlan(Self.request([tabloid], options: PrintOptions(scaleMode: .fit, marks: [.crop], bleed: 18)))
        let clip = marked.sheets[0].clip
        #expect(abs(clip.height - (756 - 2 * PrinterMarks.margin)) < 1e-9)
    }

    @Test func variableScaleStretches() {
        let page = Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 200, height: 100))
        let plan = PrintPlan(Self.request([page], options: PrintOptions(scaleMode: .variable, scaleX: 50, scaleY: 100)))
        let trim = plan.sheets[0].trim
        #expect(trim.width == 100 && trim.height == 100)
        // Centred on the printable area, then moved by the offset (x right, y down).
        #expect(trim.midX == 306 && trim.midY == 396)
        let moved = PrintPlan(Self.request([page], options: PrintOptions(offset: Point(x: 10, y: 20)))).sheets[0].trim
        #expect(moved.midX == 316 && moved.midY == 416)
        // Uniform reads scale X only.
        let uniform = PrintPlan(Self.request([page], options: PrintOptions(scaleMode: .uniform, scaleX: 200, scaleY: 50))).sheets[0].trim
        #expect(uniform.width == 400 && uniform.height == 200)
    }

    @Test func optionsReadTheirRanges() {
        let options = PrintOptions(scaleMode: .fit, scaleX: 0, scaleY: 3000, offset: Point(x: .nan, y: 1), tile: .manual, tileOverlap: -3, bleed: 900,
                                   flatness: .infinity, rasterizeDPI: 50)
        #expect(options.scaleX == 100 && options.scaleY == 100 && options.offset == .zero && options.tile == .none)
        #expect(options.tileOverlap == 0 && options.bleed == 720 && options.flatness == 0 && options.rasterizeDPI == 0)
        #expect(PrintOptions(tileOverlap: .nan, bleed: .nan).bleed == 0)
        #expect(PrintOptions(tileOverlap: 900).tileOverlap == 720)
        #expect(PrintPaper(size: Size(width: 10, height: 10), resolution: -1).resolution == nil)
        #expect(PrintPaper(size: Size(width: 10, height: 10)).imageable == Rect(x: 0, y: 0, width: 10, height: 10))
    }

    // MARK: Tiling

    /// A 24 × 36 in poster on Letter at 100%: 8 × 10.5 in tiles.
    @Test func automaticTilesAPoster() throws {
        let poster = Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 24 * Self.inch, height: 36 * Self.inch))
        let plan = PrintPlan(Self.request([poster], options: PrintOptions(tile: .automatic)))
        #expect(plan.count == 12)
        let first = try #require(plan.sheets[0].tile)
        #expect(first.columns == 3 && first.rows == 4)
        #expect(plan.sheets.map { $0.tile!.number } == Array(1...12))
        #expect(plan.sheets[4].name == "Page 1, row 2 column 2")
        // Half an inch of overlap: adjacent tiles share half an inch of artwork.
        let overlapped = PrintPlan(Self.request([poster], options: PrintOptions(tile: .automatic, tileOverlap: 36)))
        let tiles = overlapped.sheets.compactMap(\.tile)
        #expect(tiles[0].columns == 4 && tiles[0].rows == 4 && overlapped.count == 16)
        #expect(tiles[0].rect.intersection(tiles[1].rect).width == 36)
        #expect(tiles[0].rect.intersection(tiles[4].rect).height == 36)
        // Every tile is placed at the printable area's top-left at 100%.
        #expect(overlapped.sheets[5].transform.apply(tiles[5].rect.origin) == Point(x: 18, y: 18))
        #expect(tiles[5].label == "Tile 6 of 16, row 2 column 2")
        // A page that fits prints one tile; an overlap past half a tile is reduced.
        let small = PrintPlan(Self.request([Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 100, height: 100))], options: PrintOptions(tile: .automatic)))
        #expect(small.count == 1 && small.sheets[0].tile?.count == 1)
        let wide = PrintTiling.automatic(content: Rect(x: 0, y: 0, width: 300, height: 50), tileSize: Size(width: 100, height: 100), overlap: 80)
        #expect(wide.count > 2 && wide[1].rect.minX > 0)
        #expect(PrintTiling.automatic(content: Rect(x: 0, y: 0, width: 10, height: 10), tileSize: Size(width: 0, height: 5), overlap: 0).isEmpty)
    }

    /// 200% of Letter on Letter is a two-by-two poster.
    @Test func tilingAndScalingCombine() {
        let letter = Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 576, height: 756))
        let plan = PrintPlan(Self.request([letter], options: PrintOptions(scaleX: 200, tile: .automatic)))
        #expect(plan.count == 4 && plan.sheets[0].tile?.columns == 2)
    }

    @Test func manualTilingStartsAtTheZeroPoint() throws {
        let poster = Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 24 * Self.inch, height: 36 * Self.inch))
        let plan = PrintPlan(Self.request([poster], options: PrintOptions(tile: .manual), zero: [1: Point(x: 144, y: 216)]))
        #expect(plan.count == 1)
        let tile = try #require(plan.sheets[0].tile)
        #expect(tile.isManual && tile.rect.origin == Point(x: 144, y: 216) && tile.rect.width == 576)
        #expect(plan.sheets[0].transform.apply(Point(x: 144, y: 216)) == Point(x: 18, y: 18))
        #expect(plan.sheets[0].name == "Page 1")
        let moved = PrintPlan(Self.request([poster], options: PrintOptions(tile: .manual), zero: [1: Point(x: 720, y: 0)]))
        #expect(moved.sheets[0].tile?.rect.minX == 720)
        // Without a zero point the page's top-left; *Fit on paper* with manual tiling reads as none.
        #expect(PrintPlan(Self.request([poster], options: PrintOptions(tile: .manual))).sheets[0].tile?.rect.origin == .zero)
        #expect(PrintPlan(Self.request([poster], options: PrintOptions(scaleMode: .fit, tile: .manual))).sheets[0].tile == nil)
    }

    @Test func tilesCarryLabelsAndTileMarks() throws {
        let poster = Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 1200, height: 700))
        let plan = PrintPlan(Self.request([poster], options: PrintOptions(tile: .automatic, tileOverlap: 18, marks: [.crop])))
        let sheet = plan.sheets[0]
        #expect(sheet.labels.contains { $0.text == "Tile 1 of \(sheet.tile!.count), row 1 column 1" && $0.alignment == .trailing })
        // The first tile: page corner crop marks at its top-left only, tile marks along its right
        // and bottom overlaps.
        let crops = sheet.marks.filter { if case .line(let from, _) = $0 { return from.x < sheet.clip.minX || from.y < sheet.clip.minY } else { return false } }
        #expect(!crops.isEmpty)
        let overlapX = sheet.transform.apply(Point(x: sheet.tile!.rect.maxX - 18, y: 0)).x
        #expect(sheet.marks.contains { if case .line(let from, let to) = $0 { return from.x == overlapX && to.x == overlapX } else { return false } })
        // A middle tile has overlap marks on both sides.
        let middle = try #require(plan.sheets.first { $0.tile!.column == 1 && $0.tile!.row == 0 })
        let vertical = middle.marks.filter { if case .line(let from, let to) = $0 { return from.x == to.x && from.y < middle.clip.minY } else { return false } }
        #expect(vertical.count >= 2)
    }

    // MARK: Separations

    @Test func separationsPrintOneSheetPerPlate() {
        let page = Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 200, height: 100))
        let plan = PrintPlan(Self.request([page], options: PrintOptions(separations: true, plates: Self.twoSpots)))
        #expect(plan.count == 6)
        #expect(plan.sheets.map(\.name) == ["Page 1, Cyan", "Page 1, Magenta", "Page 1, Yellow", "Page 1, Black", "Page 1, PANTONE 185 C", "Page 1, Gold"])
        var plates = Self.twoSpots
        plates[2].print = false
        #expect(PrintPlan(Self.request([page], options: PrintOptions(separations: true, plates: plates))).count == 5)
        #expect(PrintPlan(Self.request([page], options: PrintOptions(separations: true, spotAsProcess: true, plates: Self.twoSpots))).count == 4)
        #expect(plan.sheets[1].plate.ink == .magenta && plan.sheets[0].plate != .composite)
        #expect(PrintPlan(Self.request([page])).sheets[0].plate.ink == nil)
        // Sheet order: page, then tile, then plate.
        let tiled = PrintPlan(Self.request([Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 1200, height: 700)), page],
                                           options: PrintOptions(separations: true, tile: .automatic)))
        let firstTile = tiled.sheets.prefix(4)
        #expect(firstTile.allSatisfy { $0.tile?.number == 1 && $0.page == 0 } && firstTile.map { $0.plate.ink! } == Ink.process)
        #expect(tiled.sheets.last?.page == 1)
    }

    @Test func separationLabelsNameInkAngleAndFrequency() {
        let page = Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 200, height: 100))
        var plates = Self.twoSpots
        plates[1].frequency = 133
        plates[4].angle = 22.5
        let plan = PrintPlan(Self.request([page], options: PrintOptions(separations: true, marks: [.separationNames, .fileNameDate],
                                                                        defaultScreen: HalftoneScreen(shape: .round, angle: 0, frequency: 150), plates: plates)))
        #expect(plan.sheets[1].labels.map(\.text).contains("Magenta 75° 133 lpi"))
        #expect(plan.sheets[4].labels.map(\.text).contains("PANTONE 185 C 22.5° 150 lpi"))
        #expect(plan.sheets[0].labels.map(\.text).contains("Poster  Page 1  2026-09-21 14:13"))
        let composite = PrintPlan(Self.request([page], options: PrintOptions(marks: [.separationNames])))
        #expect(composite.sheets[0].labels.map(\.text) == ["Composite"])
    }

    // MARK: Marks

    /// Marks keep their size and 0.25 pt weight at 25% and 400%.
    @Test func marksKeepTheirSizeAtEveryScale() {
        let page = Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 100, height: 80))
        func lengths(_ scale: Double) -> [Double] {
            let plan = PrintPlan(Self.request([page], options: PrintOptions(scaleX: scale, marks: [.crop, .registration]), paper: PrintPaper(size: Size(width: 1000, height: 1000))))
            return plan.sheets[0].marks.map { mark -> Double in
                switch mark {
                case .line(let from, let to): return hypot(to.x - from.x, to.y - from.y)
                case .registration(_, let radius): return radius
                }
            }
        }
        #expect(lengths(25) == lengths(400))
        #expect(lengths(25).filter { $0 == PrinterMarks.length }.count == 8)
        #expect(PrinterMarks.lineWidth == 0.25)
    }

    /// A 9 pt bleed moves the crop marks outward by 9 pt.
    @Test func bleedMovesCropMarksOutward() {
        let page = Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 100, height: 80))
        func firstCrop(_ bleed: Double) -> (Point, Rect) {
            let sheet = PrintPlan(Self.request([page], options: PrintOptions(marks: [.crop], bleed: bleed))).sheets[0]
            guard case .line(let from, _) = sheet.marks[0] else { return (.zero, sheet.clip) }
            return (from, sheet.clip)
        }
        let (plain, plainClip) = firstCrop(0)
        let (bled, bledClip) = firstCrop(9)
        #expect(plain.x - bled.x == 9)
        #expect(bledClip.width - plainClip.width == 18)
    }

    @Test func clippedMarksAreReported() {
        let page = Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 612, height: 792))
        let plan = PrintPlan(Self.request([page], options: PrintOptions(marks: [.crop])))
        #expect(plan.sheets[0].marksClipped && plan.clippingWarning != nil)
        let small = PrintPlan(Self.request([Self.page(number: 1, rect: Rect(x: 0, y: 0, width: 200, height: 200))], options: PrintOptions(marks: .all)))
        #expect(!small.sheets[0].marksClipped && small.clippingWarning == nil)
        #expect(PrinterMark.registration(center: .zero, radius: 4).bounds.width == 12.25)
    }

    @Test func outputAreaSheetsAreThePage() {
        let area = Self.page(number: nil, rect: Rect(x: 50, y: 50, width: 300, height: 200))
        let plan = PrintPlan(Self.request([area], options: PrintOptions(marks: [.crop, .fileNameDate]), source: .outputArea(pageOutlines: [Rect(x: 0, y: 0, width: 100, height: 100)])))
        #expect(plan.sheets[0].trim.width == 300)
        #expect(plan.sheets[0].labels[0].text.contains("Output area"))
    }
}
