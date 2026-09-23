// DXF colours (import-formats.adoc, "AutoCAD DXF"; IMG-013): the AutoCAD Color Index and true
// colours.  The 256-entry index is AutoCAD's: 1-9 are the named colours, 10-249 are 24 hues in
// 15° steps, each at five brightnesses (100, 74, 51, 41 and 31%) in a full and a pale (one third
// white) version, and 250-255 are greys.  Colour 7 is "white on a dark screen, black on paper";
// imported artwork is on paper, so it reads black.

import Foundation
import WTRender

enum DXFImportColors {
    /// The index's colours as 0xRRGGBB, 0 unused (BYBLOCK).
    static let table: [Int] = {
        var table = [0x000000, 0xFF0000, 0xFFFF00, 0x00FF00, 0x00FFFF, 0x0000FF, 0xFF00FF, 0xFFFFFF, 0x414141, 0x808080]
        let brightness: [Double] = [255, 189, 129, 104, 79]
        for index in 10...249 {
            let hue = Double((index - 10) / 10) * 15
            let pale = index % 2 == 1
            let value = brightness[(index % 10) / 2]
            // HSV at full saturation and value, then the pale version mixed a third of the way
            // from white.
            func channel(_ n: Double) -> Double {
                let k = (n + hue / 60).truncatingRemainder(dividingBy: 6)
                let c = 1 - max(0, min(k, 4 - k, 1))
                return pale ? (170 + 85 * c) / 255 : c
            }
            let rgb = [channel(5), channel(3), channel(1)].map { Int(($0 * value).rounded()) }
            table.append(rgb[0] << 16 | rgb[1] << 8 | rgb[2])
        }
        table += [0x333333, 0x505050, 0x696969, 0x828282, 0xBEBEBE, 0xFFFFFF]
        return table
    }()

    /// `0xRRGGBB` as a colour.
    static func color(rgb: Int) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    /// An index colour as printed: 7 is black on paper; out-of-range indices read black.
    static func color(index: Int) -> Color {
        guard (1...255).contains(index), index != 7 else {
            return .black
        }
        return color(rgb: table[index])
    }

    /// Whether a colour is white for the *Convert white … to black* options: index 7 or 255, or
    /// a colour at 98% or more in every channel.
    static func isWhite(_ color: Color) -> Bool {
        let rgb = color.srgb
        return rgb.x >= 0.98 && rgb.y >= 0.98 && rgb.z >= 0.98
    }
}
