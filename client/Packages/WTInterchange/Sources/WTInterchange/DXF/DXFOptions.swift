// DXF export options (export-vector.adoc, "DXF options"; `DxfOptions` in
// interchange/v1/export_options.proto).

import Foundation

public struct DXFOptions: ExportOptions, Hashable {
    public enum Version: Hashable, Sendable {
        /// AutoCAD 2018 (`AC1032`), UTF-8.
        case v2018
        /// AutoCAD 2000 (`AC1015`).
        case v2000
        /// R12 (`AC1009`): polylines only, no handles; the most widely read by cutter software.
        case r12
    }

    public enum Units: Hashable, Sendable {
        /// The document's units; the scene carries none yet, so points (see the DXF note).
        case document
        case millimeters
        case inches
        case points

        /// Drawing units per point.
        var perPoint: Double {
            switch self {
            case .millimeters: return 25.4 / 72
            case .inches: return 1 / 72
            case .document, .points: return 1
            }
        }

        /// `$INSUNITS`: 1 inches, 4 millimetres, 0 unitless (DXF has no point unit).
        var insUnits: Int {
            switch self {
            case .millimeters: return 4
            case .inches: return 1
            case .document, .points: return 0
            }
        }
    }

    public var version: Version
    public var units: Units
    /// Curves as `SPLINE` entities (2000 and later); false flattens them into polylines.
    public var splines: Bool
    /// Polyline flattening tolerance in output units; 0 means 0.1 mm.
    public var tolerance: Double
    /// Each document layer as a DXF layer; false puts everything on layer 0.
    public var layersFromDocument: Bool
    /// Strokes written as their outlines (a router) rather than their centerlines (a cutter).
    public var outlineStrokes: Bool

    public init(version: Version = .v2018, units: Units = .millimeters, splines: Bool = false, tolerance: Double = 0, layersFromDocument: Bool = true, outlineStrokes: Bool = false) {
        self.version = version
        self.units = units
        self.splines = splines
        self.tolerance = tolerance
        self.layersFromDocument = layersFromDocument
        self.outlineStrokes = outlineStrokes
    }

    public static var defaults: DXFOptions { DXFOptions() }

    /// The flattening tolerance in points.
    var tolerancePoints: Double {
        tolerance > 0 ? tolerance / units.perPoint : 0.1 * 72 / 25.4
    }

    func validate() throws {
        guard tolerance.isFinite, tolerance >= 0 else {
            throw ExportError.invalidOption("The curve tolerance cannot be negative.")
        }
        if splines && version == .r12 {
            throw ExportError.invalidOption("R12 has no spline entities: choose Polylines or a later version.")
        }
    }
}
