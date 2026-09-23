// Gradient transparency from soft masks (IMG-009): a PDF shading has no alpha, so gradient
// opacity -- a translucent gradient, or a gradient mask over a flat fill -- is written as a
// luminosity soft mask whose group paints one shading.  Such a mask is read back as the stop
// opacities of the gradient it masks, or, over a flat fill, as a gradient of that colour whose
// opacity follows the mask.  Any other soft mask is left out with a note.

import Foundation
import WTGeometry
import WTRender

struct PDFImportAlphaRamp {
    let function: PDFImportFunction
    let space: PDFImportColorSpace
    let domain: [Double]
    /// The mask's own gradient in page space (its geometry and grey ramp).
    let mask: Gradient?

    /// The ramp of soft mask `mask` set while the CTM was `ctm`, nil unless it is a luminosity
    /// mask painting exactly one shading.
    init?(_ mask: PDFImportDict, ctm: AffineTransform, session: PDFImportSession) {
        guard mask.name("S") == "Luminosity", let group = mask.stream("G") else {
            return nil
        }
        var shadings: [String] = []
        var transform = AffineTransform.identity
        var parser = PDFImportParser(group.data)
        parser.forEachOperator { op, operands in
            let numbers = operands.compactMap(\.number)
            if op == "cm", numbers.count == 6, shadings.isEmpty {
                transform = AffineTransform(a: numbers[0], b: numbers[1], c: numbers[2], d: numbers[3], tx: numbers[4], ty: numbers[5]).concatenating(transform)
            } else if op == "sh", let name = operands.first?.name {
                shadings.append(name)
            }
        }
        let resources = group.dict.dict("Resources")
        guard shadings.count == 1, let shading = resources?.dict("Shading")?[shadings[0]], let dict = shading.dict,
              let function = dict["Function"].flatMap(PDFImportFunction.parse),
              let space = dict["ColorSpace"].flatMap({ PDFImportColorSpace.parse($0, resources: resources) }) else {
            return nil
        }
        self.function = function
        self.space = space
        domain = dict.numbers("Domain").flatMap { $0.count >= 2 ? $0 : nil } ?? [0, 1]
        let matrix = group.dict.numbers("Matrix").flatMap { $0.count == 6 ? AffineTransform(a: $0[0], b: $0[1], c: $0[2], d: $0[3], tx: $0[4], ty: $0[5]) : nil } ?? .identity
        if case .gradient(let gradient) = PDFImportShading.paint(shading, toPage: transform.concatenating(matrix).concatenating(ctm), resources: resources, session: session) {
            self.mask = gradient
        } else {
            self.mask = nil
        }
    }

    /// The mask's luminosity at ramp position `t` (0...1).
    func alpha(at t: Double) -> Double {
        PDFImportAlphaRamp.luminance(space.color(function.evaluate([domain[0] + t * (domain[1] - domain[0])])) ?? .black)
    }

    static func luminance(_ color: Color) -> Double {
        let rgb = color.srgb
        return min(max(0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z, 0), 1)
    }

    /// `paint` seen through the mask.
    func apply(to paint: ImportedPaint) -> ImportedPaint {
        switch paint {
        case .gradient(var gradient):
            gradient.stops = gradient.stops.map { Gradient.Stop(offset: $0.offset, color: $0.color.withAlpha(multipliedBy: alpha(at: $0.offset))) }
            return .gradient(gradient)
        case .solid(let color) where mask != nil:
            var gradient = mask!
            gradient.stops = gradient.stops.map { Gradient.Stop(offset: $0.offset, color: color.withAlpha(multipliedBy: PDFImportAlphaRamp.luminance($0.color))) }
            return .gradient(gradient)
        default:
            return paint
        }
    }
}
