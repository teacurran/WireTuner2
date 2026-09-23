// The in-app halftone screener (PRINT-009; docs/_includes/printing/output-devices.adoc,
// "In-app screener").  A plate is rasterized at device resolution to 8-bit gray in bands, off
// the caller's actor, then thresholded pixel by pixel against the screen of whatever paints
// there: the plate's screen, or an object's own screen.  Objects with their own screens are
// found by a second, aliased render of the same list in which every object paints the index
// of its screen, so each pixel takes the screen of the top-most object painting it and the
// boundary between two screens is the object's edge.  The result is a 1-bit plate.
//
// The screen grid is anchored at the sheet's top-left device pixel; angles are measured
// counter-clockwise on the page.

import CoreGraphics
import Foundation
import WTGeometry

/// A 1-bit plate: one bit per pixel, most significant bit the left-most pixel, 1 where ink
/// prints; row 0 at the top.
public struct BitPlate: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public var bits: [UInt8]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytesPerRow = (width + 7) / 8
        bits = [UInt8](repeating: 0, count: bytesPerRow * height)
    }

    /// Whether ink prints at column `x`, row `y`.
    public func isInked(x: Int, y: Int) -> Bool {
        guard (0..<width).contains(x), (0..<height).contains(y) else {
            return false
        }
        return bits[y * bytesPerRow + x / 8] & (0x80 >> UInt8(x % 8)) != 0
    }

    /// The fraction of pixels inked in `rect` (pixel columns and rows, clamped), or the whole
    /// plate.
    public func coverage(in rect: (x: Int, y: Int, width: Int, height: Int)? = nil) -> Double {
        let area = rect ?? (0, 0, width, height)
        let x0 = max(area.x, 0), y0 = max(area.y, 0)
        let x1 = min(area.x + area.width, width), y1 = min(area.y + area.height, height)
        guard x1 > x0, y1 > y0 else {
            return 0
        }
        var inked = 0
        for y in y0..<y1 {
            for x in x0..<x1 where isInked(x: x, y: y) {
                inked += 1
            }
        }
        return Double(inked) / Double((x1 - x0) * (y1 - y0))
    }

    /// The plate as a 1-bit DeviceGray image (ink black), drawn onto the sheet.
    public func makeImage() -> CGImage {
        let inverted = bits.map { ~$0 }
        let provider = CGDataProvider(data: Data(inverted) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// Sets rows `rows` from `band`, whose row 0 is `rows.lowerBound`.
    mutating func copyRows(from band: BitPlate, at row: Int) {
        let start = row * bytesPerRow
        let count = band.bits.count
        bits.replaceSubrange(start..<(start + count), with: band.bits)
    }
}

/// Screens rasterized plates.
public struct Screener: Sendable {
    /// Device pixels per inch: the print queue's resolution, else the document's
    /// `rasterize_dpi`.
    public var resolution: Double
    /// Rows rendered at a time.
    public var bandHeight: Int

    public init(resolution: Double, bandHeight: Int = 512) {
        self.resolution = max(resolution.isFinite ? resolution : 72, 1)
        self.bandHeight = max(bandHeight, 1)
    }

    // MARK: Thresholding

    /// `plate` thresholded with `screen`, its row 0 at sheet row `originRow`.
    public func screen(_ plate: GrayPlate, with screen: HalftoneScreen, originRow: Int = 0) -> BitPlate {
        self.screen(plate, screens: [screen], index: nil, originRow: originRow)
    }

    /// `plate` thresholded pixel by pixel with `screens[index]`, `index` giving each pixel's
    /// screen (its gray value; nil: every pixel the first screen).
    public func screen(_ plate: GrayPlate, screens: [HalftoneScreen], index: GrayPlate?, originRow: Int = 0) -> BitPlate {
        precondition(!screens.isEmpty, "at least the plate's screen")
        let grids = screens.map { ScreenGrid(screen: $0, resolution: resolution) }
        var result = BitPlate(width: plate.width, height: plate.height)
        let width = plate.width, bytesPerRow = result.bytesPerRow
        let indexPixels = index?.pixels ?? []
        result.bits.withUnsafeMutableBufferPointer { output in
            plate.pixels.withUnsafeBufferPointer { gray in
                indexPixels.withUnsafeBufferPointer { indices in
                    let buffers = ScreenBuffers(output: output.baseAddress!, gray: gray.baseAddress!, index: index == nil ? nil : indices.baseAddress)
                    DispatchQueue.concurrentPerform(iterations: plate.height) { row in
                        ScreenGrid.thresholdRow(
                            gray: buffers.gray + row * width, grayStride: 1,
                            index: buffers.index.map { $0 + row * width }, indexStride: 1,
                            width: width, sheetRow: originRow + row, firstColumn: 0, grids: grids,
                            output: buffers.output + row * bytesPerRow
                        )
                    }
                }
            }
        }
        return result
    }

    // MARK: Plates

    /// Errors from `screenPlate`.
    public enum ScreenError: Error, Equatable {
        /// The page rectangle has no pixels at this resolution.
        case emptyPage
        /// A band's bitmap could not be allocated.
        case outOfMemory
    }

    /// Band tiles are at most this many pixels wide (a multiple of 8, so no two tiles share
    /// an output byte; bitmaps are limited to 16,384 pixels on a side).
    static let tileWidth = 8192

    /// `plate` of `displayList` over the pasteboard rectangle `page`, rasterized at this
    /// resolution band by band (bands in parallel) and screened: each object with an entry in
    /// `objectScreens` (keyed by its top-level node id; the effective screen WTModel resolved:
    /// its own, else its nearest ancestor's) with that screen, everything else with
    /// `plateScreen`.  `ignoreObjectScreens` (`ignore_object_halftones`) screens everything
    /// with the plate's.  `isCancelled` is polled before each band.
    public func screenPlate(
        _ displayList: DisplayList,
        plate: Ink,
        renderer: PlateRenderer,
        page: Rect,
        plateScreen: HalftoneScreen,
        objectScreens: [NodeID: HalftoneScreen] = [:],
        ignoreObjectScreens: Bool = false,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> BitPlate {
        let scale = resolution / 72
        let width = Int((page.width * scale).rounded())
        let height = Int((page.height * scale).rounded())
        guard width > 0, height > 0, width <= 1 << 20, height <= 1 << 20 else {
            throw ScreenError.emptyPage
        }
        let assignment = ignoreObjectScreens ? nil : ScreenAssignment(displayList, plateScreen: plateScreen, objectScreens: objectScreens)
        let grids = (assignment?.screens ?? [plateScreen]).map { ScreenGrid(screen: $0, resolution: resolution) }
        let plateRenderer = renderer.renderer(for: plate)
        var result = BitPlate(width: width, height: height)
        let bytesPerRow = result.bytesPerRow
        let bands = (height + bandHeight - 1) / bandHeight
        let columns = (width + Screener.tileWidth - 1) / Screener.tileWidth
        let cancelled = CancellationFlag(), failed = CancellationFlag()
        let rowsPerBand = bandHeight
        result.bits.withUnsafeMutableBufferPointer { output in
            let target = ScreenOutput(bits: output.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: bands * columns) { tile in
                guard !cancelled.isSet, !failed.isSet else { return }
                if isCancelled() {
                    cancelled.set()
                    return
                }
                let row = tile / columns * rowsPerBand
                let rows = min(rowsPerBand, height - row)
                let column = tile % columns * Screener.tileWidth
                let columnsWide = min(Screener.tileWidth, width - column)
                let viewport = Viewport(
                    scrollOrigin: Point(x: page.minX + Double(column) / scale, y: page.minY + Double(row) / scale),
                    size: Size(width: Double(columnsWide) / scale, height: Double(rows) / scale)
                )
                // The tile's pixel grid is the page's: exactly `rows` × `columnsWide` pixels.
                guard let surface = BitmapSurface(width: columnsWide, height: rows) else {
                    failed.set()
                    return
                }
                surface.context.scaleBy(x: scale, y: scale)
                plateRenderer.render(displayList, viewport: viewport, into: surface.context)
                let indexSurface = assignment.flatMap { $0.indexSurface(viewport: viewport, width: columnsWide, rows: rows, scale: scale) }
                let gray = UnsafePointer(surface.context.data!.assumingMemoryBound(to: UInt8.self))
                let index = indexSurface.map { UnsafePointer($0.context.data!.assumingMemoryBound(to: UInt8.self)) }
                for line in 0..<rows {
                    ScreenGrid.thresholdRow(
                        gray: gray + line * surface.context.bytesPerRow, grayStride: 4,
                        index: index.map { $0 + line * indexSurface!.context.bytesPerRow }, indexStride: 4,
                        width: columnsWide, sheetRow: row + line, firstColumn: column, grids: grids,
                        output: target.bits + (row + line) * bytesPerRow + column / 8
                    )
                }
                withExtendedLifetime(indexSurface) {}
            }
        }
        if cancelled.isSet {
            throw CancellationError()
        }
        if failed.isSet {
            throw ScreenError.outOfMemory
        }
        return result
    }

    /// As `screenPlate`, off the caller's actor; cancelling the task stops it between bands.
    public func screenPlate(
        _ displayList: DisplayList,
        plate: Ink,
        renderer: PlateRenderer,
        page: Rect,
        plateScreen: HalftoneScreen,
        objectScreens: [NodeID: HalftoneScreen] = [:],
        ignoreObjectScreens: Bool = false
    ) async throws -> BitPlate {
        let screener = self
        let task = Task.detached(priority: .userInitiated) {
            try screener.screenPlate(displayList, plate: plate, renderer: renderer, page: page, plateScreen: plateScreen, objectScreens: objectScreens, ignoreObjectScreens: ignoreObjectScreens, isCancelled: { Task.isCancelled })
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// Set once by whichever band sees the cancellation.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

/// The buffers one thresholding pass shares across rows; each row writes only its own bytes.
private struct ScreenBuffers: @unchecked Sendable {
    let output: UnsafeMutablePointer<UInt8>
    let gray: UnsafePointer<UInt8>
    let index: UnsafePointer<UInt8>?
}

private struct ScreenOutput: @unchecked Sendable {
    let bits: UnsafeMutablePointer<UInt8>
}

/// Which screen paints each pixel: the list recoloured so every top-level item paints its
/// screen's index, drawn without anti-aliasing.
struct ScreenAssignment: Sendable {
    let screens: [HalftoneScreen]
    let list: DisplayList

    /// Nil when no object has a screen of its own (every pixel takes the plate's).
    init?(_ displayList: DisplayList, plateScreen: HalftoneScreen, objectScreens: [NodeID: HalftoneScreen]) {
        guard !objectScreens.isEmpty, !displayList.nodeIDs.isEmpty else {
            return nil
        }
        var screens = [plateScreen]
        var items: [DisplayItem] = []
        var used = false
        for (index, item) in displayList.items.enumerated() {
            var slot = 0
            if let node = displayList.nodeIDs[index], let screen = objectScreens[node] {
                if let existing = screens.firstIndex(of: screen) {
                    slot = existing
                } else if screens.count < 256 {
                    screens.append(screen)
                    slot = screens.count - 1
                }
                used = used || slot != 0
            }
            items.append(item.painted(Color(white: Double(slot) / 255)))
        }
        guard used else {
            return nil
        }
        self.screens = screens
        list = DisplayList(canvas: displayList.canvas, items: items, nodeIDs: displayList.nodeIDs)
    }

    /// The band's screen indices: the red channel of an aliased render.
    func indexSurface(viewport: Viewport, width: Int, rows: Int, scale: Double) -> BitmapSurface? {
        guard let surface = BitmapSurface(width: width, height: rows) else {
            return nil
        }
        surface.context.setShouldAntialias(false)
        surface.context.setAllowsAntialiasing(false)
        surface.context.scaleBy(x: scale, y: scale)
        CoreGraphicsRenderer(background: .black).render(list, viewport: viewport, into: surface.context)
        return surface
    }
}

/// A screen's cell grid in device pixels, walked in fixed point: a cell coordinate is held
/// times 2^24, so the position within the cell is the low 24 bits and the threshold table's
/// row and column are their top 8.
struct ScreenGrid: Sendable {
    static let fractionBits: Int64 = 24
    static let one = Double(1 << 24)

    let thresholds: [UInt16]
    /// Cell coordinates per device pixel along x, fixed point.
    let du: Int64
    let dv: Int64
    let cos: Double
    let sin: Double
    let size: Double

    init(screen: HalftoneScreen, resolution: Double) {
        thresholds = ThresholdCell.cached(screen.shape).thresholds
        size = resolution / screen.frequency
        let radians = screen.angle * .pi / 180
        cos = Foundation.cos(radians)
        sin = Foundation.sin(radians)
        // Page y points down; the angle is counter-clockwise on the page.
        du = Int64((cos / size * ScreenGrid.one).rounded())
        dv = Int64((-sin / size * ScreenGrid.one).rounded())
    }

    /// The fixed-point cell position of the centre of pixel `column` in sheet row `row`.
    /// Columns advance by the fixed-point step, so a row screened in tiles matches the row
    /// screened whole bit for bit.
    func rowStart(_ row: Int, column: Int = 0) -> (u: Int64, v: Int64) {
        let x = 0.5
        let up = -(Double(row) + 0.5)
        let u = (x * cos + up * sin) / size
        let v = (-x * sin + up * cos) / size
        return (Int64((u * ScreenGrid.one).rounded()) &+ Int64(column) &* du, Int64((v * ScreenGrid.one).rounded()) &+ Int64(column) &* dv)
    }

    @inline(__always)
    static func cellIndex(_ u: Int64, _ v: Int64) -> Int {
        Int((v >> 16) & 0xFF) << 8 | Int((u >> 16) & 0xFF)
    }

    /// One row: pixel `x` inks where its coverage (`255 - gray[x × grayStride]`) exceeds the
    /// threshold of its screen (`grids[index[x × indexStride]]`, or the first).
    static func thresholdRow(gray: UnsafePointer<UInt8>, grayStride: Int, index: UnsafePointer<UInt8>?, indexStride: Int, width: Int, sheetRow: Int, firstColumn: Int, grids: [ScreenGrid], output: UnsafeMutablePointer<UInt8>) {
        if index == nil || grids.count == 1 {
            let grid = grids[0]
            var (u, v) = grid.rowStart(sheetRow, column: firstColumn)
            grid.thresholds.withUnsafeBufferPointer { table in
                for x in 0..<width {
                    let level = gray[x * grayStride]
                    if level < 255 && UInt16(255 - level) &* 257 > table[cellIndex(u, v)] {
                        output[x >> 3] |= 0x80 >> UInt8(x & 7)
                    }
                    u &+= grid.du
                    v &+= grid.dv
                }
            }
            return
        }
        var positions = grids.map { $0.rowStart(sheetRow, column: firstColumn) }
        for x in 0..<width {
            let which = min(Int(index![x * indexStride]), grids.count - 1)
            let level = gray[x * grayStride]
            let position = positions[which]
            if level < 255 && UInt16(255 - level) &* 257 > grids[which].thresholds[cellIndex(position.u, position.v)] {
                output[x >> 3] |= 0x80 >> UInt8(x & 7)
            }
            for screen in positions.indices {
                positions[screen].u &+= grids[screen].du
                positions[screen].v &+= grids[screen].dv
            }
        }
    }
}

extension DisplayItem {
    /// The item with everything it paints in `color`, opaque, without effects or transparency:
    /// its footprint (the screener's index pass).
    func painted(_ color: Color) -> DisplayItem {
        func solid(_ paint: Paint) -> Paint {
            paint.isNone ? .none : .solid(color)
        }
        switch self {
        case .fill(var item):
            item.paint = solid(item.paint)
            return .fill(item)
        case .stroke(var item):
            item.paint = solid(item.paint)
            return .stroke(item)
        case .path(var item):
            let elements = item.appearance.items.map { element -> AppearanceItem in
                switch element {
                case .fill(var fill):
                    fill.paint = solid(fill.paint)
                    fill.overprint = false
                    return .fill(fill)
                case .stroke(var stroke):
                    stroke.paint = solid(stroke.paint)
                    stroke.overprint = false
                    return .stroke(stroke)
                }
            }
            item.appearance = Appearance(elements, raster: item.appearance.raster)
            item.inheritedEffects = []
            return .path(item)
        case .image(let item):
            return .fill(FillItem(path: DisplayPath(rect: item.visibleRect), paint: .solid(color), transform: item.transform))
        case .text(var item):
            item.color = color
            item.overprint = false
            return .text(item)
        case .group(let group):
            return .group(GroupItem(
                children: group.children.map { $0.painted(color) },
                clip: group.clip,
                clipRule: group.clipRule,
                transform: group.transform,
                hiddenInKeyline: group.hiddenInKeyline
            ))
        }
    }
}
