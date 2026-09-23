// Expanding what WTRender derives on read into plain paths (IO-017: "expand live vector effects;
// expand blends to steps").  WTRender keeps its effect pipeline, stroke expansion and blend
// resolution internal, but its public Core Graphics renderer writes them to PDF as the filled
// outlines it draws.  The capture renders an item through `CoreGraphicsRenderer.renderPDF` and
// reads the page's content stream back with `CGPDFScanner`: filled paths in sRGB colours, clips,
// constant alpha and transparency groups become flat nodes in pasteboard space.  Anything else
// the stream contains -- a shading, an image, a soft mask, a pattern, a blend mode -- means the
// item is not plain vector artwork, and the capture reports nil so the flattener renders it to
// an image instead.

import CoreGraphics
import Foundation
import WTGeometry
import WTRender

enum VectorCapture {
    /// `items` as flat vector nodes in pasteboard space, or nil when their drawing is not plain
    /// filled vector artwork.  `region` is the pasteboard area captured (the items' bounds).
    static func capture(_ items: [DisplayItem], region: Rect) -> [FlatNode]? {
        guard !region.isEmpty else {
            return []
        }
        let viewport = Viewport(scrollOrigin: region.origin, zoom: 1, size: Size(width: region.width, height: region.height))
        // A PDF context over a finite media box always renders.
        let data = CoreGraphicsRenderer().renderPDF(DisplayList(canvas: "capture", items: items), viewport: viewport)!
        return parse(pdf: data, region: region)
    }

    /// The first page of `pdf` read back as flat nodes, `region` being the pasteboard rectangle
    /// its media box shows.
    static func parse(pdf: Data, region: Rect) -> [FlatNode]? {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) else {
            return nil
        }
        let toPasteboard = AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: region.minX, ty: region.maxY)
        let state = CaptureState(toPasteboard: toPasteboard, region: region)
        let stream = CGPDFContentStreamCreateWithPage(page)
        state.scan(stream)
        return state.result
    }
}

/// The scanner's state: graphics state stack, current path and the group tree being built.
final class CaptureState {
    struct Graphics {
        var ctm: AffineTransform = .identity
        var fill = Color.black
        var alpha = 1.0
        /// Components the current fill colour space takes (3 RGB, 1 grey); 0 for a space the
        /// capture does not understand.
        var components = 1
    }

    /// A group being filled: closed when the graphics stack drops below `depth`.
    struct Frame {
        var depth: Int
        var group: FlatGroup
    }

    let toPasteboard: AffineTransform
    let region: Rect
    var graphics = Graphics()
    var stack: [Graphics] = []
    var path = DisplayPath()
    var current = Point.zero
    var subpathStart = Point.zero
    var pendingClip: FillRule?
    var frames: [Frame]
    var failed = false

    init(toPasteboard: AffineTransform, region: Rect) {
        self.toPasteboard = toPasteboard
        self.region = region
        frames = [Frame(depth: 0, group: FlatGroup(children: []))]
    }

    /// The captured nodes, or nil when the stream held something the capture cannot express.
    var result: [FlatNode]? {
        guard !failed else {
            return nil
        }
        while frames.count > 1 {
            closeFrame()
        }
        return frames[0].group.children
    }

    // MARK: Scanning

    nonisolated(unsafe) private static let table: CGPDFOperatorTableRef = {
        let table = CGPDFOperatorTableCreate()!
        func on(_ name: String, _ callback: @escaping CGPDFOperatorCallback) {
            CGPDFOperatorTableSetCallback(table, name, callback)
        }
        on("q") { _, info in CaptureState.of(info).push() }
        on("Q") { _, info in CaptureState.of(info).pop() }
        on("cm") { scanner, info in
            let state = CaptureState.of(info)
            if let n = state.numbers(scanner, 6) {
                state.graphics.ctm = AffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(state.graphics.ctm)
            }
        }
        on("m") { scanner, info in
            let state = CaptureState.of(info)
            if let n = state.numbers(scanner, 2) { state.move(Point(x: n[0], y: n[1])) }
        }
        on("l") { scanner, info in
            let state = CaptureState.of(info)
            if let n = state.numbers(scanner, 2) { state.line(Point(x: n[0], y: n[1])) }
        }
        on("c") { scanner, info in
            let state = CaptureState.of(info)
            if let n = state.numbers(scanner, 6) { state.curve(Point(x: n[0], y: n[1]), Point(x: n[2], y: n[3]), Point(x: n[4], y: n[5])) }
        }
        on("v") { scanner, info in
            let state = CaptureState.of(info)
            if let n = state.numbers(scanner, 4) { state.curve(nil, Point(x: n[0], y: n[1]), Point(x: n[2], y: n[3])) }
        }
        on("y") { scanner, info in
            let state = CaptureState.of(info)
            if let n = state.numbers(scanner, 4) { state.curve(Point(x: n[0], y: n[1]), Point(x: n[2], y: n[3]), Point(x: n[2], y: n[3])) }
        }
        on("h") { _, info in CaptureState.of(info).closeSubpath() }
        on("re") { scanner, info in
            let state = CaptureState.of(info)
            if let n = state.numbers(scanner, 4) { state.rectangle(Rect(x: n[0], y: n[1], width: n[2], height: n[3])) }
        }
        on("f") { _, info in CaptureState.of(info).paint(.nonZero) }
        on("F") { _, info in CaptureState.of(info).paint(.nonZero) }
        on("f*") { _, info in CaptureState.of(info).paint(.evenOdd) }
        on("n") { _, info in CaptureState.of(info).paint(nil) }
        on("W") { _, info in CaptureState.of(info).pendingClip = .nonZero }
        on("W*") { _, info in CaptureState.of(info).pendingClip = .evenOdd }
        on("cs") { scanner, info in CaptureState.of(info).setColorSpace(scanner) }
        on("sc") { scanner, info in CaptureState.of(info).setColor(scanner) }
        on("scn") { scanner, info in CaptureState.of(info).setColor(scanner) }
        on("rg") { scanner, info in
            let state = CaptureState.of(info)
            state.graphics.components = 3
            state.setColor(scanner)
        }
        on("g") { scanner, info in
            let state = CaptureState.of(info)
            state.graphics.components = 1
            state.setColor(scanner)
        }
        on("gs") { scanner, info in CaptureState.of(info).setGraphicsState(scanner) }
        on("Do") { scanner, info in CaptureState.of(info).drawObject(scanner) }
        // Painting the capture cannot express: strokes, shadings, inline images, text, CMYK.
        for name in ["S", "s", "B", "B*", "b", "b*", "sh", "BI", "BT", "k", "K", "SC", "SCN", "CS", "RG", "G"] {
            on(name) { _, info in CaptureState.of(info).failed = true }
        }
        return table
    }()

    static func of(_ info: UnsafeMutableRawPointer?) -> CaptureState {
        Unmanaged<CaptureState>.fromOpaque(info!).takeUnretainedValue()
    }

    func scan(_ stream: CGPDFContentStreamRef) {
        let scanner = CGPDFScannerCreate(stream, CaptureState.table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    /// `count` numbers from the operand stack, in operand order.
    func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [Double]? {
        var values = [Double](repeating: 0, count: count)
        for index in stride(from: count - 1, through: 0, by: -1) {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else {
                failed = true
                return nil
            }
            values[index] = Double(value)
        }
        return values
    }

    // MARK: Graphics state

    func push() {
        stack.append(graphics)
    }

    func pop() {
        if let saved = stack.popLast() {
            graphics = saved
        }
        while frames.count > 1 && frames[frames.count - 1].depth > stack.count {
            closeFrame()
        }
    }

    /// Closes the innermost group into its parent; a group that changes nothing is spliced in.
    func closeFrame() {
        let frame = frames.removeLast()
        if frame.group.isEffective {
            frames[frames.count - 1].group.children.append(.group(frame.group))
        } else {
            frames[frames.count - 1].group.children.append(contentsOf: frame.group.children)
        }
    }

    // MARK: Paths

    func move(_ point: Point) {
        current = point
        subpathStart = point
        path.move(to: toPasteboard.apply(graphics.ctm.apply(point)))
    }

    func line(_ point: Point) {
        current = point
        path.addLine(to: toPasteboard.apply(graphics.ctm.apply(point)))
    }

    func curve(_ control1: Point?, _ control2: Point, _ end: Point) {
        let map = graphics.ctm.concatenating(toPasteboard)
        path.addCubicCurve(control1: map.apply(control1 ?? current), control2: map.apply(control2), to: map.apply(end))
        current = end
    }

    func closeSubpath() {
        path.close()
        current = subpathStart
    }

    func rectangle(_ rect: Rect) {
        move(Point(x: rect.minX, y: rect.minY))
        line(Point(x: rect.maxX, y: rect.minY))
        line(Point(x: rect.maxX, y: rect.maxY))
        line(Point(x: rect.minX, y: rect.maxY))
        closeSubpath()
    }

    /// Fills the current path with `rule` (nil: `n`, no paint), then applies a pending clip.
    func paint(_ rule: FillRule?) {
        if let rule, !path.isEmpty {
            let color = graphics.fill.withAlpha(multipliedBy: graphics.alpha)
            frames[frames.count - 1].group.children.append(.path(FlatPath(path: path, paint: .color(color), style: .fill(rule))))
        }
        if let clip = pendingClip {
            openClip(path, rule: clip)
        }
        pendingClip = nil
        path = DisplayPath()
    }

    /// A clip lasting until the graphics state is restored.  A rectangle covering the whole
    /// captured region clips nothing and is dropped.
    func openClip(_ clip: DisplayPath, rule: FillRule) {
        if let bounds = clip.controlBounds, CaptureState.isRectangle(clip), bounds.expanded(by: 0.01).contains(region) {
            return
        }
        frames.append(Frame(depth: stack.count, group: FlatGroup(children: [], clip: FlatClip(path: clip, rule: rule))))
    }

    /// Whether `path` is one axis-aligned rectangle (four lines, closed).
    static func isRectangle(_ path: DisplayPath) -> Bool {
        let points = path.elements.compactMap { element -> Point? in
            switch element {
            case .move(let point), .line(let point): return point
            default: return nil
            }
        }
        guard points.count == 4, path.elements.count == 5 else {
            return false
        }
        let xs = Set(points.map { ($0.x * 1000).rounded() })
        let ys = Set(points.map { ($0.y * 1000).rounded() })
        return xs.count == 2 && ys.count == 2
    }

    // MARK: Colour

    func setColorSpace(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else {
            failed = true
            return
        }
        let text = String(cString: name)
        switch text {
        case "DeviceRGB":
            graphics.components = 3
        case "DeviceGray":
            graphics.components = 1
        default:
            graphics.components = components(ofResource: text, in: scanner)
        }
        graphics.fill = .black
    }

    /// The component count of a named `/ICCBased` colour space resource (1 or 3), 0 otherwise.
    func components(ofResource name: String, in scanner: CGPDFScannerRef) -> Int {
        var array: CGPDFArrayRef?
        var family: UnsafePointer<CChar>?
        var stream: CGPDFStreamRef?
        guard let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ColorSpace", name),
              CGPDFObjectGetValue(object, .array, &array), let array,
              CGPDFArrayGetName(array, 0, &family), let family, String(cString: family) == "ICCBased",
              CGPDFArrayGetStream(array, 1, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream)
        else {
            return 0
        }
        var count: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(dictionary, "N", &count)
        return count == 1 || count == 3 ? Int(count) : 0
    }

    func setColor(_ scanner: CGPDFScannerRef) {
        guard graphics.components > 0, let values = numbers(scanner, graphics.components) else {
            failed = true
            return
        }
        graphics.fill = values.count == 3 ? Color(red: values[0], green: values[1], blue: values[2]) : Color(white: values[0])
    }

    // MARK: ExtGState and XObjects

    func setGraphicsState(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFScannerPopName(scanner, &name), let name,
              let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ExtGState", name),
              CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary
        else {
            failed = true
            return
        }
        var alpha: CGPDFReal = 1
        if CGPDFDictionaryGetNumber(dictionary, "ca", &alpha) {
            graphics.alpha = Double(alpha)
        }
        var mask: UnsafePointer<CChar>?
        var maskObject: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dictionary, "SMask", &maskObject), !(CGPDFDictionaryGetName(dictionary, "SMask", &mask) && mask.map { String(cString: $0) } == "None") {
            failed = true
        }
        var blend: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "BM", &blend), let blend, !["Normal", "Compatible"].contains(String(cString: blend)) {
            failed = true
        }
    }

    func drawObject(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        var stream: CGPDFStreamRef?
        guard CGPDFScannerPopName(scanner, &name), let name,
              let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name),
              CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream)
        else {
            failed = true
            return
        }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" else {
            failed = true  // an image
            return
        }
        push()
        var matrix: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, let values = CaptureState.reals(matrix), values.count == 6 {
            graphics.ctm = AffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]).concatenating(graphics.ctm)
        }
        var group: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, "Group", &group) {
            frames.append(Frame(depth: stack.count, group: FlatGroup(children: [], opacity: graphics.alpha)))
            graphics.alpha = 1
        }
        var box: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "BBox", &box), let box, let values = CaptureState.reals(box), values.count == 4 {
            rectangle(Rect(Point(x: values[0], y: values[1]), Point(x: values[2], y: values[3])))
            pendingClip = .nonZero
            paint(nil)
        }
        var resources: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources {
            let content = CGPDFContentStreamCreateWithStream(stream, resources, CGPDFScannerGetContentStream(scanner))
            scan(content)
            CGPDFContentStreamRelease(content)
        } else {
            failed = true
        }
        pop()
    }

    static func reals(_ array: CGPDFArrayRef) -> [Double]? {
        var values: [Double] = []
        for index in 0..<CGPDFArrayGetCount(array) {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &value) else {
                return nil
            }
            values.append(Double(value))
        }
        return values
    }
}
