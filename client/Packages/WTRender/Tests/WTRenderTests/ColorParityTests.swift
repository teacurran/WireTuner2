import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// REND-007 for the colour pipeline and placed images: tagged colours in every space, CMYK
/// through a custom Working CMYK, gradients and raster effects, on sRGB and Display P3 tiles,
/// with and without a soft proof, and decoded images with crops, tints and a source profile.
@Suite(.enabled(if: MetalAvailability.isAvailable, "no Metal device: parity run incomplete"))
struct ColorParityTests {
    static let colors: [Color] = [
        Color(red: 0.9, green: 0.2, blue: 0.1),
        Color(displayP3Red: 1, green: 0, blue: 0),
        Color(labL: 60, a: -40, b: 50),
        Color(oklchL: 0.7, chroma: 0.3, hue: 250),
        Color(cyan: 1, magenta: 0.2, yellow: 0, black: 0.1),
        Color(cyan: 0, magenta: 0, yellow: 1, black: 0, alpha: 0.5),
    ]

    static var list: DisplayList {
        var items: [DisplayItem] = colors.enumerated().map { index, color in
            .fill(FillItem(path: DisplayPath(rect: Rect(x: Double(index % 3) * 20 + 2, y: Double(index / 3) * 20 + 2, width: 16, height: 16)), paint: .solid(color)))
        }
        items.append(.fill(FillItem(path: DisplayPath(rect: Rect(x: 2, y: 44, width: 56, height: 12)), paint: .gradient(Gradient(.linear, from: Color(cyan: 1, magenta: 0, yellow: 0, black: 0), to: Color(displayP3Red: 1, green: 0.5, blue: 0))))))
        items.append(.text(TextRunItem(text: "x", origin: Point(x: 62, y: 20), bounds: Rect(x: 62, y: 4, width: 10, height: 16), color: Color(labL: 30, a: 60, b: 0))))
        items.append(.group(GroupItem(children: [.fill(FillItem(path: DisplayPath(rect: Rect(x: 62, y: 30, width: 12, height: 12)), paint: .solid(Color(oklabL: 0.5, a: 0.1, b: -0.1))))], opacity: 0.6)))
        return DisplayList(canvas: "colors", items: items)
    }

    static let managements: [(String, ColorManagement)] = [
        ("sRGB", .standard),
        ("P3 heavy press", ColorManagement(workingSpace: .displayP3, cmykProfile: TestPresses.heavy)),
        ("P3 proof", ColorManagement(workingSpace: .displayP3).with(proof: WTColor.ProofSetup(profile: TestPresses.light, simulatePaperWhite: true))),
        ("sRGB composite proof", ColorManagement.standard.with(proof: WTColor.ProofSetup(profile: TestPresses.light, separations: WTColor.ProfileRegistry.shared.defaultCMYK))),
    ]

    static func compare(_ list: DisplayList, management: ColorManagement, store: ImageStore? = nil, scale: Double = 1) throws -> [String] {
        let context = try #require(MetalAvailability.context)
        var cg = CoreGraphicsRenderer(background: .white).with(colorManagement: management)
        var metal = MetalRenderer(context: context, background: .white).with(colorManagement: management)
        cg.imageStore = store
        metal.imageStore = store
        let geometry = TileGeometry(zoomStep: ZoomStep(nearest: scale), rotationDegrees: 0)
        let area = list.bounds!.expanded(by: 2)
        var failing: [String] = []
        let keys = geometry.tiles(coveringPasteboardRect: area, canvas: list.canvas)
        if let store {
            // Decode the levels these tiles draw before comparing, so both renderers see them.
            for key in keys {
                _ = cg.renderTile(list, key: key, geometry: geometry)
            }
            store.waitUntilIdle()
        }
        for key in keys {
            let reference = try #require(cg.renderTile(list, key: key, geometry: geometry))
            let candidate = try #require(metal.renderTile(list, key: key, geometry: geometry))
            #expect(reference.colorSpace?.name == management.colorSpace.name && candidate.colorSpace?.name == management.colorSpace.name)
            let parity = TileParity(reference: try #require(BitmapSurface(drawing: reference)), candidate: try #require(BitmapSurface(drawing: candidate)))
            if !parity.passes {
                let url = Triptych.write(reference: try #require(BitmapSurface(drawing: reference)), candidate: try #require(BitmapSurface(drawing: candidate)), name: "\(list.canvas)-\(key)")
                failing.append("\(key): \(parity) -> \(url?.path ?? "unwritten")")
            }
        }
        return failing
    }

    @Test(arguments: managements.map(\.0))
    func colourPipelinesMatchCoreGraphics(name: String) throws {
        let management = try #require(Self.managements.first { $0.0 == name }?.1)
        for scale in [1.0, 2.0] {
            let failing = try Self.compare(Self.list, management: management, scale: scale)
            #expect(failing.isEmpty, "\(name)@\(scale)x: \(failing)")
        }
    }

    @Test func placedImagesMatchCoreGraphics() throws {
        let store = ImageRenderingTests.store(["q": ImageRenderingTests.quadrants(), "g": ImageFixtures.grayImage(width: 8, height: 8) { x, _ in UInt8(x * 32) }])
        let list = DisplayList(canvas: "images", items: [
            .image(ImageItem(assetID: "q", rect: Rect(x: 0, y: 0, width: 32, height: 32), transform: AffineTransform.rotation(radians: .pi / 18).concatenating(.translation(x: 8, y: 4)), crop: Rect(x: 0.25, y: 0, width: 0.75, height: 1))),
            .image(ImageItem(assetID: "g", rect: Rect(x: 0, y: 0, width: 24, height: 24), transform: .translation(x: 40, y: 8), mode: .grayscale, tint: Color(cyan: 1, magenta: 0, yellow: 0, black: 0))),
            .image(ImageItem(assetID: "missing", rect: Rect(x: 0, y: 0, width: 16, height: 16), transform: .translation(x: 40, y: 40))),
        ])
        // Warm the store so both renderers see decoded pixels.
        var warm = CoreGraphicsRenderer()
        warm.imageStore = store
        _ = warm.renderBitmap(list, viewport: Viewport(size: Size(width: 80, height: 80)))
        store.waitUntilIdle()
        for (name, management) in Self.managements {
            let failing = try Self.compare(list, management: management, store: store)
            #expect(failing.isEmpty, "\(name): \(failing)")
        }
    }
}
