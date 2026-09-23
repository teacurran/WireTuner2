import CoreGraphics
import WTGeometry
import WTRender

// Conversions between the pasteboard geometry (WTGeometry, y-down, Double) and Core Graphics.
// WTRender has the same bridge internally; the app keeps its own so it depends only on
// WTRender's public API.

extension Point {
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    init(_ point: CGPoint) { self.init(x: Double(point.x), y: Double(point.y)) }
}

extension Vector {
    init(_ size: CGSize) { self.init(dx: Double(size.width), dy: Double(size.height)) }
}

extension Rect {
    var cgRect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }
    init(_ rect: CGRect) { self.init(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height)) }
}

extension Size {
    init(_ size: CGSize) { self.init(width: Double(size.width), height: Double(size.height)) }
    var cgSize: CGSize { CGSize(width: width, height: height) }
}

extension WTGeometry.AffineTransform {
    var cgAffineTransform: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

extension Color {
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
