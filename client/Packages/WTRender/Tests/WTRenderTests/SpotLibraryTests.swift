import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTRender

/// CMS-014: spot colour libraries and their preview.
@Suite struct SpotLibraryTests {
    /// The placeholder inks' published sRGB values (tools/spot-libraries/placeholder.csv's Lab
    /// through the CIE formulas, Bradford D50 → D65).
    static let reference: [String: [Int]] = [
        "WT Dev Red": [218, 34, 38], "WT Dev Blue": [32, 68, 175], "WT Dev Green": [34, 159, 94],
        "WT Dev Yellow": [244, 221, 44], "WT Dev Violet": [132, 57, 156], "WT Dev Gray": [145, 145, 145],
    ]

    @Test func managedPreviewsMatchThePublishedSRGBWithinTwoLevels() {
        let store = WTColor.SpotLibraryStore()
        let settings = WTColor.SpotPreviewSettings()
        let library = WTColor.SpotLibrary.placeholder
        #expect(store.libraryIDs == [library.id] && store.library(library.id) == library)
        for ink in library.inks {
            let preview = store.previewColor(library: library.id, ink: ink.name, nominal: .zero, settings: settings)
            #expect(preview.libraryAvailable && preview.profile == WTColor.ProfileRegistry.shared.sRGB)
            #expect(preview.color == Color(labL: ink.lab.x, a: ink.lab.y, b: ink.lab.z))
            let levels = preview.components.map { Int(($0 * 255).rounded()) }
            let expected = Self.reference[ink.name]!
            #expect(zip(levels, expected).allSatisfy { abs($0 - $1) <= 2 }, "\(ink.name): \(levels) vs \(expected)")
            #expect(preview.cgColor()?.numberOfComponents == 4)
        }
        // Cached per (library, ink, tint, settings).
        #expect(store.cachedPreviewCount == library.inks.count)
        _ = store.previewColor(library: library.id, ink: "WT Dev Red", nominal: .zero, settings: settings)
        #expect(store.cachedPreviewCount == library.inks.count)
        store.removeCachedPreviews()
        #expect(store.cachedPreviewCount == 0)
    }

    @Test func tintsBlendTowardPaperInLabOrScaleTheMix() {
        let store = WTColor.SpotLibraryStore()
        let id = WTColor.SpotLibrary.placeholder.id
        let half = store.previewColor(library: id, ink: "WT Dev Blue", nominal: .zero, tint: 0.5, settings: WTColor.SpotPreviewSettings())
        #expect(half.color == Color(labL: 66, a: 10, b: -31))
        let none = store.previewColor(library: id, ink: "WT Dev Blue", nominal: .zero, tint: 0, settings: WTColor.SpotPreviewSettings())
        #expect(none.components.allSatisfy { $0 > 0.99 })
        // A tint outside 0...1 (or not a number) is clamped.
        let over = store.previewColor(library: id, ink: "WT Dev Blue", nominal: .zero, tint: .nan, settings: WTColor.SpotPreviewSettings())
        #expect(over.color == Color(labL: 32, a: 20, b: -62))
        let unmanaged = WTColor.SpotPreviewSettings(managed: false)
        let mix = store.previewColor(library: id, ink: "WT Dev Blue", nominal: .zero, tint: 0.5, settings: unmanaged)
        #expect(mix.libraryAvailable && mix.profile == WTColor.ProfileRegistry.shared.defaultCMYK)
        #expect(mix.components == [0.5, 0.4, 0, 0.025])
        #expect(mix.color == Color(cyan: 0.5, magenta: 0.4, yellow: 0, black: 0.025))
    }

    @Test func toggleManagementChangesTheChipOnly() {
        let store = WTColor.SpotLibraryStore()
        let id = WTColor.SpotLibrary.placeholder.id
        let managed = store.previewColor(library: id, ink: "WT Dev Red", nominal: .zero, settings: WTColor.SpotPreviewSettings(managed: true))
        let unmanaged = store.previewColor(library: id, ink: "WT Dev Red", nominal: .zero, settings: WTColor.SpotPreviewSettings(managed: false))
        #expect(managed != unmanaged && managed.color.space == .lab && unmanaged.color.space == .cmyk)
    }

    @Test func unknownLibrariesAndInksPreviewFromTheNominalMix() {
        let store = WTColor.SpotLibraryStore()
        let nominal = SIMD4<Double>(0.1, 0.2, 0.3, 0.4)
        for (library, ink) in [("pantone-solid-coated", "PANTONE 300 C"), (WTColor.SpotLibrary.placeholder.id, "Withdrawn")] {
            let preview = store.previewColor(library: library, ink: ink, nominal: nominal, settings: WTColor.SpotPreviewSettings())
            #expect(!preview.libraryAvailable && preview.components == [0.1, 0.2, 0.3, 0.4])
            #expect(preview.color == Color(cyan: 0.1, magenta: 0.2, yellow: 0.3, black: 0.4))
        }
        #expect(store.library("pantone-solid-coated") == nil)
    }

    @Test func pendingWorkingProfilesPreviewThroughTheDefaults() {
        let registry = WTColor.ProfileRegistry()
        let converter = WTColor.Converter(registry: registry)
        let store = WTColor.SpotLibraryStore(converter: converter)
        let missingRGB = WTColor.ProfileRef(name: "Gone RGB", sha256: Data(repeating: 1, count: 32), space: .rgb)
        let missingCMYK = WTColor.ProfileRef(name: "Gone CMYK", sha256: Data(repeating: 2, count: 32), space: .cmyk)
        let settings = WTColor.SpotPreviewSettings(rgbProfile: missingRGB, cmykProfile: missingCMYK, registry: registry)
        let id = WTColor.SpotLibrary.placeholder.id
        #expect(store.previewColor(library: id, ink: "WT Dev Red", nominal: .zero, settings: settings).profile == registry.sRGB)
        let unknown = store.previewColor(library: "x", ink: "y", nominal: SIMD4(0, 0, 0, 1), settings: settings)
        #expect(unknown.profile == registry.defaultCMYK)
        #expect(WTColor.SpotPreview(components: [0], profile: missingRGB, libraryAvailable: true, color: .black).cgColor(registry: registry) == nil)
    }

    @Test func theResourceFormatRoundTripsAndMatchesTheGenerator() throws {
        let library = WTColor.SpotLibrary.placeholder
        let data = library.encoded()
        // tools/spot-libraries/generate.py --id wiretuner-development --name "WireTuner Development
        // Spot" --version 1 placeholder.csv writes exactly these bytes.
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == "379ed07d4650d49c0e175038fc3703658ff8d996c3d276a07ea064b02733268b")
        #expect(WTColor.SpotLibrary(decoding: data) == library)
        #expect(library.ink(named: "WT Dev Gray")?.cmyk == SIMD4(0, 0, 0, 0.55))
        // Unknown fields and varints are skipped; malformed bytes are refused.
        var extended = data
        extended.append(contentsOf: [0x28, 0x05])   // field 5, varint 5
        #expect(WTColor.SpotLibrary(decoding: extended) == library)
        let emptyInk = WTColor.SpotLibrary(decoding: Data([0x22, 0x02, 0x48, 0x01]))
        #expect(emptyInk?.inks == [WTColor.SpotLibrary.Ink(name: "", lab: .zero, cmyk: .zero)])
        let sparse = WTColor.SpotLibrary(id: "s", name: "", inks: [WTColor.SpotLibrary.Ink(name: "", lab: .zero, cmyk: .zero)])
        #expect(WTColor.SpotLibrary(decoding: sparse.encoded()) == sparse)
        for bad: [UInt8] in [[0x08], [0x0A, 0x05, 0x41], [0x09, 0, 0, 0, 0, 0, 0, 0, 0], [0x15, 0x00], [0x80], [0x22, 0x01, 0x80], [0x22, 0x02, 0x0B, 0x00]] {
            #expect(WTColor.SpotLibrary(decoding: Data(bad)) == nil, "\(bad)")
        }
    }

    @Test func librariesLoadLazilyFromTheResourceFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "spot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vendor = WTColor.SpotLibrary(id: "vendor", name: "Vendor", version: "2026", inks: [
            WTColor.SpotLibrary.Ink(name: "Vendor 1", lab: SIMD3(50, 0, 0), cmyk: SIMD4(0, 0, 0, 0.5)),
        ])
        try vendor.encoded().write(to: directory.appending(path: "vendor.binpb"))
        try Data([0x80]).write(to: directory.appending(path: "broken.binpb"))
        try Data().write(to: directory.appending(path: "notes.txt"))
        let store = WTColor.SpotLibraryStore(directory: directory)
        #expect(store.libraryIDs == ["broken", "vendor", "wiretuner-development"])
        #expect(store.library("vendor") == vendor)
        #expect(store.library("broken") == nil && store.library("broken") == nil)
        let preview = store.previewColor(library: "vendor", ink: "Vendor 1", nominal: .zero, settings: WTColor.SpotPreviewSettings())
        #expect(preview.libraryAvailable && abs(preview.components[0] - preview.components[1]) < 0.01)
    }
}

/// DOC-032: the library thumbnail render.
@Suite struct ThumbnailRendererTests {
    @Test func sizesFollowTheLongEdge() {
        #expect(ThumbnailRenderer.pixelSize(of: Rect(x: 0, y: 0, width: 612, height: 792))! == (396, 512))
        #expect(ThumbnailRenderer.pixelSize(of: Rect(x: 0, y: 0, width: 2000, height: 1), longEdge: 1024)! == (1024, 1))
        #expect(ThumbnailRenderer.pixelSize(of: Rect(x: 0, y: 0, width: 0, height: 10)) == nil)
        #expect(ThumbnailRenderer.pixelSize(of: Rect(x: 0, y: 0, width: .infinity, height: 10)) == nil)
        #expect(ThumbnailRenderer.pixelSize(of: Rect(x: 0, y: 0, width: 10, height: 10), longEdge: 0) == nil)
        #expect(ThumbnailRenderer.png(Corpus.solidRect, page: .zero) == nil)
    }

    @Test func theFirstPageRendersAsATransparentSRGBPNG() throws {
        // The page is 80 × 60 pt at (0, 0); the red rectangle covers (10, 10)–(70, 50).
        let page = Rect(x: 0, y: 0, width: 80, height: 60)
        let data = try #require(ThumbnailRenderer.png(Corpus.solidRect, page: page))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 512 && image.height == 384)
        #expect(image.alphaInfo != .none && image.alphaInfo != .noneSkipFirst && image.alphaInfo != .noneSkipLast)
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)
        let surface = try #require(BitmapSurface(drawing: image))
        #expect(surface.pixel(x: 5, y: 5).alpha == 0)
        let inside = surface.pixel(x: 256, y: 192)
        #expect(inside.alpha == 255 && inside.red > 200 && inside.green < 40)
        // An offset page renders the same artwork relative to its corner.
        let shifted = DisplayList(canvas: "t", items: Corpus.solidRect.items.map { item in
            guard case .fill(var fill) = item else { return item }
            fill.transform = .translation(x: 100, y: 200)
            return .fill(fill)
        })
        let moved = try #require(ThumbnailRenderer.image(shifted, page: Rect(x: 100, y: 200, width: 80, height: 60), longEdge: 80))
        let movedSurface = try #require(BitmapSurface(drawing: moved))
        #expect(movedSurface.pixel(x: 40, y: 30).red > 200 && movedSurface.pixel(x: 2, y: 2).alpha == 0)
    }
}
