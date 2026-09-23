import AppKit
import UniformTypeIdentifiers
import WTModel
import WTProto
import WTRender

/// Colours on the pasteboard (color-mixer.adoc, "the `ColorRef` pasteboard type"; COLOR-008 and
/// COLOR-011): a drag or copy writes the `ColorRefPasteboard` payload under
/// `com.villagecompute.wiretuner.colorref` and an `NSColor` for other applications (Display P3
/// when the colour is, sRGB otherwise); a drop reads the payload, else an `NSColor` -- kept in
/// its own space when that is sRGB or Display P3, otherwise converted into the *Default color
/// space for new colors* (gamut-mapped into sRGB).
enum ColorDrag {
    static let type = NSPasteboard.PasteboardType(ColorRefPasteboard.typeIdentifier)
    static let utType = UTType(exportedAs: ColorRefPasteboard.typeIdentifier)
    /// What colour drop targets accept: the payload, or a plain `NSColor`.
    static let dropTypes: [UTType] = [utType, UTType(importedAs: NSPasteboard.PasteboardType.color.rawValue)]

    /// Writes `payload` (and its `NSColor`) to `pasteboard`, replacing its contents.
    static func write(_ payload: ColorRefPasteboard, to pasteboard: NSPasteboard) {
        let foreign = archived(payload.foreignColor)
        pasteboard.declareTypes(foreign == nil ? [type] : [type, .color], owner: nil)
        pasteboard.setData(payload.data(), forType: type)
        if let foreign { pasteboard.setData(foreign, forType: .color) }
    }

    /// `color` as other applications read an `NSColor` off a pasteboard (a keyed archive).
    static func archived(_ color: RenderColor?) -> Data? {
        color.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: nsColor($0), requiringSecureCoding: true) }
    }

    /// A drag's item: the payload's data under the colour type, and its `NSColor`.
    static func itemProvider(_ payload: ColorRefPasteboard) -> NSItemProvider {
        let provider = NSItemProvider(item: payload.data() as NSData, typeIdentifier: ColorRefPasteboard.typeIdentifier)
        if let data = archived(payload.foreignColor) {
            provider.registerDataRepresentation(forTypeIdentifier: NSPasteboard.PasteboardType.color.rawValue, visibility: .all) { load in
                load(data, nil)
                return nil
            }
        }
        return provider
    }

    /// The colour `pasteboard` carries: the payload, else an `NSColor` read as an unnamed colour.
    static func read(from pasteboard: NSPasteboard, defaultSpace: Color.Space) -> ColorRefPasteboard? {
        if let data = pasteboard.data(forType: type), let payload = ColorRefPasteboard(data: data) {
            return payload
        }
        guard let color = NSColor(from: pasteboard) else { return nil }
        let stored = self.color(color, defaultSpace: defaultSpace)
        return ColorRefPasteboard(ref: ColorResolver.inline(stored), color: stored)
    }

    /// An `NSColor` for another application: `color` in its own space when that is sRGB or
    /// Display P3.
    static func nsColor(_ color: Color) -> NSColor {
        let c = color.components
        if color.space == .displayP3 {
            return NSColor(displayP3Red: c.x, green: c.y, blue: c.z, alpha: color.alpha)
        }
        return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    /// An incoming `NSColor` as a stored colour: sRGB and Display P3 as they are, anything else
    /// in `defaultSpace` (Display P3 as it is, sRGB gamut-mapped).
    static func color(_ color: NSColor, defaultSpace: Color.Space) -> Color {
        // A pattern or catalog colour has no colour space to ask for.
        let space = color.type == .componentBased ? color.colorSpace : nil
        if space == .sRGB, let srgb = color.usingColorSpace(.sRGB) {
            return Color(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
        }
        let p3 = color.usingColorSpace(.displayP3) ?? NSColor.black.usingColorSpace(.displayP3)!
        let wide = Color(displayP3Red: p3.redComponent, green: p3.greenComponent, blue: p3.blueComponent)
        if space == .displayP3 || defaultSpace == .displayP3 { return wide }
        return WTColor.Gamut.map(wide, into: .sRGB)
    }
}
