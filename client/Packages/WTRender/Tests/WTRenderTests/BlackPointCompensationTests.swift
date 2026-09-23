import CoreGraphics
import Foundation
import Testing
@testable import WTRender

/// Regression: ColorSync's own black point compensation moved the white point (sRGB white
/// into Generic CMYK came out as about C 11% M 8% under relative colorimetric).  The converter
/// now compensates black points itself; white prints no ink.
@Suite struct BlackPointCompensationTests {
    let converter = WTColor.Converter(registry: WTColor.ProfileRegistry())
    var registry: WTColor.ProfileRegistry { converter.registry }

    func cmyk(_ color: Color, bpc: Bool, intent: WTColor.RenderingIntent = .relativeColorimetric) throws -> [Double] {
        try #require(converter.convert(color, to: registry.defaultCMYK, intent: intent, blackPointCompensation: bpc))
    }

    func coreGraphics(_ color: Color) -> [Double] {
        let converted = color.cgColor.converted(to: CGColorSpace(name: CGColorSpace.genericCMYK)!, intent: .relativeColorimetric, options: nil)!
        return converted.components!.prefix(4).map(Double.init)
    }

    @Test func whitePrintsNoInkWithOrWithoutCompensation() throws {
        for bpc in [false, true] {
            let white = try cmyk(.white, bpc: bpc)
            #expect(white.allSatisfy { $0 < 0.5 / 255 }, "bpc \(bpc): \(white)")
        }
        #expect(PlateContext(plate: .cyan).coverage(of: .white) < 0.5 / 255)
        #expect(PlateContext(plate: .magenta).coverage(of: .white) < 0.5 / 255)
    }

    @Test func blackIsTheProfilesRichBlack() throws {
        let plain = try cmyk(.black, bpc: false)
        let expected = coreGraphics(.black)
        #expect(zip(plain, expected).allSatisfy { abs($0 - $1) <= 1.0 / 255 }, "\(plain) vs \(expected)")
        let compensated = try cmyk(.black, bpc: true)
        #expect(compensated.reduce(0, +) > 2.5 && compensated[3] > 0.8, "rich black: \(compensated)")
        // Compensated black is the profile's black point: taken back to Lab, it is as dark as
        // the device's darkest, within the black point's own round trip (about 2 L*).
        let back = try #require(converter.convert(Color(cyan: compensated[0], magenta: compensated[1], yellow: compensated[2], black: compensated[3]), to: registry.sRGB, blackPointCompensation: false))
        let darkest = try #require(converter.convert(Color(cyan: plain[0], magenta: plain[1], yellow: plain[2], black: plain[3]), to: registry.sRGB, blackPointCompensation: false))
        #expect(zip(back, darkest).allSatisfy { abs($0 - $1) <= 6.0 / 255 }, "\(back) vs \(darkest)")
    }

    @Test(arguments: [
        Color(red: 0.5, green: 0.2, blue: 0.8), Color(red: 0.9, green: 0.6, blue: 0.1),
        Color(red: 0.25, green: 0.5, blue: 0.25), Color(white: 0.5), Color(red: 0, green: 0.68, blue: 0.94),
    ])
    func midColorsMatchCoreGraphics(color: Color) throws {
        let ours = try cmyk(color, bpc: false)
        let theirs = coreGraphics(color)
        #expect(zip(ours, theirs).allSatisfy { abs($0 - $1) <= 1.0 / 255 }, "\(ours) vs \(theirs)")
        // Compensation keeps mid tones close and only lifts the shadows.
        let compensated = try cmyk(color, bpc: true)
        #expect(zip(compensated, ours).allSatisfy { abs($0 - $1) <= 0.08 })
    }

    @Test func compensationStillMattersInTheShadows() throws {
        let dark = Color(white: 0.1)
        #expect(try cmyk(dark, bpc: true) != cmyk(dark, bpc: false))
        // Other intents ignore the flag (it is a relative colorimetric adjustment).
        #expect(try cmyk(dark, bpc: true, intent: .perceptual) == cmyk(dark, bpc: false, intent: .perceptual))
    }

    /// A staged chain (compensation between profiles) converts image pixels too.
    @Test func stagedTransformsConvertPremultipliedPixels() throws {
        let step = { (profile: WTColor.ProfileRef) in WTColor.ChainStep(profile: profile, intent: .relativeColorimetric, blackPointCompensation: true) }
        let transform = try #require(converter.transform([step(registry.sRGB), step(registry.defaultCMYK), step(registry.sRGB)]))
        var pixels: [UInt8] = [255, 255, 255, 255, 0, 0, 0, 0, 128, 64, 32, 128]
        transform.convertRGBA8(&pixels, width: 3, height: 1, bytesPerRow: 12)
        #expect(pixels[0] >= 250 && pixels[1] >= 250 && pixels[2] >= 250 && pixels[3] == 255)
        #expect(pixels[4] == 0 && pixels[7] == 0)
        #expect(pixels[11] == 128 && pixels[8] <= 128)
        // Lab in, compensated into CMYK.
        let lab = try #require(converter.convert(Color(labL: 100, a: 0, b: 0), to: registry.defaultCMYK, blackPointCompensation: true))
        #expect(lab.allSatisfy { $0 < 1.0 / 255 })
    }
}
