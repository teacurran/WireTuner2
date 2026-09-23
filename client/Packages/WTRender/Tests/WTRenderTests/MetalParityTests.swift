import WTGeometry
import CoreGraphics
import Foundation
import Testing
@testable import WTRender

/// Whether this machine can run the Metal side of REND-006/007.  Without a GPU the suites
/// below are *skipped* -- reported as not run, never as passed -- which is what CI reads as an
/// incomplete run (docs/spec/testing.adoc, "Geometry and rendering").
enum MetalAvailability {
    static let context = MetalContext.shared
    static var isAvailable: Bool { context != nil }
}

/// REND-007: every golden-corpus list through both renderers over identical tile keys, at 1×,
/// 2× and 4×, at 0°, 15° and 90°, in Preview and Keyline (and the case's own mode), compared
/// tile by tile with the stated tolerance.  Failing tiles are written as triptychs.
@Suite(.enabled(if: MetalAvailability.isAvailable, "no Metal device: parity run incomplete"))
struct MetalParityTests {
    static let scales: [Double] = [1, 2, 4]
    static let rotations: [Double] = [0, 15, 90]

    struct Configuration: CustomStringConvertible {
        let reference: ReferenceCase
        let scale: Double
        let rotation: Double
        let mode: ViewMode

        var description: String {
            "\(reference.name)@\(Int(scale))x/\(Int(rotation))deg/\(mode.rawValue)"
        }

        var geometry: TileGeometry {
            TileGeometry(zoomStep: ZoomStep(nearest: scale), rotationDegrees: rotation)
        }

        /// Every tile the corpus view (and anything the list paints outside it) touches.
        var keys: [TileKey] {
            let area = (reference.list.bounds ?? Rect(x: 0, y: 0, width: 1, height: 1))
                .union(Rect(x: 0, y: 0, width: reference.viewSize.width, height: reference.viewSize.height))
                .expanded(by: 4)
            return geometry.tiles(coveringPasteboardRect: area, canvas: reference.list.canvas)
        }

        var cg: CoreGraphicsRenderer {
            CoreGraphicsRenderer(background: .white, viewMode: mode, overprintPreview: reference.overprintPreview)
        }

        func metal(_ context: MetalContext) -> MetalRenderer {
            MetalRenderer(context: context, background: .white, viewMode: mode, overprintPreview: reference.overprintPreview)
        }
    }

    static func configurations(for reference: ReferenceCase) -> [Configuration] {
        var modes: [ViewMode] = [.preview, .keyline]
        if !modes.contains(reference.viewMode) {
            modes.append(reference.viewMode)
        }
        var result: [Configuration] = []
        for scale in scales {
            for rotation in rotations {
                for mode in modes {
                    result.append(Configuration(reference: reference, scale: scale, rotation: rotation, mode: mode))
                }
            }
        }
        return result
    }

    /// One tile's comparison.
    struct TileResult {
        let key: TileKey
        let parity: TileParity
        let reference: BitmapSurface
        let candidate: BitmapSurface
    }

    static func compare(_ configuration: Configuration, metal: MetalRenderer, keys: [TileKey]? = nil) throws -> [TileResult] {
        let geometry = configuration.geometry
        let list = configuration.reference.list
        return try (keys ?? configuration.keys).map { key in
            let reference = try #require(configuration.cg.renderTile(list, key: key, geometry: geometry).flatMap(BitmapSurface.init(drawing:)))
            let candidate = try #require(metal.renderTile(list, key: key, geometry: geometry).flatMap(BitmapSurface.init(drawing:)))
            return TileResult(key: key, parity: TileParity(reference: reference, candidate: candidate), reference: reference, candidate: candidate)
        }
    }

    @Test(arguments: ReferenceCorpus.cases.map(\.name))
    func corpusTilesMatchCoreGraphics(name: String) throws {
        let context = try #require(MetalAvailability.context)
        let reference = try #require(ReferenceCorpus.cases.first { $0.name == name })
        var tiles = 0
        var failing: [String] = []
        for configuration in Self.configurations(for: reference) {
            for result in try Self.compare(configuration, metal: configuration.metal(context)) {
                tiles += 1
                if !result.parity.passes {
                    let label = "\(configuration)/\(result.key)"
                    let url = Triptych.write(reference: result.reference, candidate: result.candidate, name: label)
                    failing.append("\(label): \(result.parity) -> \(url?.path ?? "unwritten")")
                }
            }
        }
        #expect(tiles > 0)
        #expect(failing.isEmpty, "\(failing.count) of \(tiles) tiles fail parity:\n\(failing.joined(separator: "\n"))")
    }
}

/// REND-007's self-test: with every declared fill rule deliberately swapped in the Metal path,
/// the harness fails exactly the tiles where the rule decides the pixels -- the tiles where
/// Core Graphics itself, given the swapped rules, fails parity with the correct render.
@Suite(.enabled(if: MetalAvailability.isAvailable, "no Metal device: parity run incomplete"))
struct MetalFillRuleSelfTests {
    static func swappingRules(_ items: [DisplayItem]) -> [DisplayItem] {
        items.map { item in
            switch item {
            case .fill(var fill):
                fill.rule = fill.rule == .nonZero ? .evenOdd : .nonZero
                return .fill(fill)
            case .path(var path):
                path.appearance.items = path.appearance.items.map { element in
                    guard case .fill(var fill) = element else { return element }
                    fill.rule = fill.rule == .nonZero ? .evenOdd : .nonZero
                    return .fill(fill)
                }
                return .path(path)
            case .group(var group):
                group.children = swappingRules(group.children)
                return .group(group)
            case .stroke, .image, .text:
                return item
            }
        }
    }

    @Test(arguments: ReferenceCorpus.cases.map(\.name))
    func misSetFillRuleFailsExactlyTheAffectedTiles(name: String) throws {
        let context = try #require(MetalAvailability.context)
        let reference = try #require(ReferenceCorpus.cases.first { $0.name == name })
        let swapped = DisplayList(canvas: reference.list.canvas, items: Self.swappingRules(reference.list.items))
        var affectedCount = 0
        for configuration in MetalParityTests.configurations(for: reference) {
            var metal = configuration.metal(context)
            metal.swapsFillRules = true
            let geometry = configuration.geometry
            var expected: Set<TileKey> = []
            for key in configuration.keys {
                let correct = try #require(configuration.cg.renderTile(reference.list, key: key, geometry: geometry).flatMap(BitmapSurface.init(drawing:)))
                let wrong = try #require(configuration.cg.renderTile(swapped, key: key, geometry: geometry).flatMap(BitmapSurface.init(drawing:)))
                if !TileParity(reference: correct, candidate: wrong).passes {
                    expected.insert(key)
                }
            }
            let failing = Set(try MetalParityTests.compare(configuration, metal: metal).filter { !$0.parity.passes }.map(\.key))
            #expect(failing == expected, "\(configuration): failing \(failing.sorted { $0.description < $1.description }) expected \(expected.sorted { $0.description < $1.description })")
            affectedCount += expected.count
        }
        let decidesRules = ["fillRules", "multiContourRules"].contains(name)
        #expect((affectedCount > 0) == decidesRules, "\(name): \(affectedCount) affected tiles")
    }
}
