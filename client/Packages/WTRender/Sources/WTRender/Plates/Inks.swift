// Inks and ink coverage for separations (PRINT-007; docs/_includes/printing/output-devices.adoc,
// "Plate mode in WTRender").  A separation renders the composite display list once per plate;
// every colour resolves to the coverage of each ink it prints with.  `Ink` mirrors the
// document's `Ink` message (a process ink or a spot swatch), `SpotInk` rides on a `Color` so a
// resolved spot colour keeps its identity through the display list.

import WTGeometry

/// A spot ink a colour stands for: which ink, its name for plate labels, and the tint
/// (0...1) the colour prints at on the ink's own plate.
public struct SpotInk: Hashable, Sendable {
    /// Which ink.  Registration colour (marks and labels) prints on every plate.
    public enum Identity: Hashable, Sendable {
        /// A spot colour swatch, by node id.
        case swatch(NodeID)
        /// Registration colour: full strength on every plate of a separated job.
        case registration
    }

    public var identity: Identity
    public var name: String
    /// Coverage on the ink's plate, 0...1.
    public var tint: Double

    public init(_ identity: Identity, name: String, tint: Double = 1) {
        self.identity = identity
        self.name = name
        self.tint = min(max(tint.isFinite ? tint : 1, 0), 1)
    }

    /// The spot swatch `swatch` at `tint`.
    public init(swatch: NodeID, name: String, tint: Double = 1) {
        self.init(.swatch(swatch), name: name, tint: tint)
    }

    /// The same ink at `amount` of its current tint.
    public func tinted(_ amount: Double) -> SpotInk {
        SpotInk(identity, name: name, tint: tint * amount)
    }

    /// Registration colour at full strength.
    public static let registration = SpotInk(.registration, name: "Registration")
}

extension Color {
    /// Registration colour: black on screen and in composite output, 100% on every plate.
    public static let registration = Color(cyan: 1, magenta: 1, yellow: 1, black: 1).asSpot(.registration)
}

/// One plate of a separated job: a process ink or a spot swatch (`Ink` in `print.proto`).
public enum Ink: Hashable, Sendable, CustomStringConvertible {
    case cyan
    case magenta
    case yellow
    case black
    case spot(NodeID)

    /// The four process inks in plate order.
    public static let process: [Ink] = [.cyan, .magenta, .yellow, .black]

    /// The default screen angle (printing.adoc, "Composite or separations"): 15° cyan, 75°
    /// magenta, 0° yellow, 45° black and every spot ink.
    public var defaultAngle: Double {
        switch self {
        case .cyan: return 15
        case .magenta: return 75
        case .yellow: return 0
        case .black, .spot: return 45
        }
    }

    public var description: String {
        switch self {
        case .cyan: return "Cyan"
        case .magenta: return "Magenta"
        case .yellow: return "Yellow"
        case .black: return "Black"
        case .spot(let id): return "Spot \(id)"
        }
    }
}

/// How much of every ink a colour prints with, each 0...1.
public struct InkCoverage: Hashable, Sendable {
    public var cyan: Double
    public var magenta: Double
    public var yellow: Double
    public var black: Double
    /// Spot inks by swatch.
    public var spots: [NodeID: Double]
    /// Registration colour: `registration` on every plate, whatever the ink.
    public var registration: Double

    public init(cyan: Double = 0, magenta: Double = 0, yellow: Double = 0, black: Double = 0, spots: [NodeID: Double] = [:], registration: Double = 0) {
        self.cyan = cyan
        self.magenta = magenta
        self.yellow = yellow
        self.black = black
        self.spots = spots
        self.registration = registration
    }

    /// The coverage on `ink`'s plate.
    public subscript(ink: Ink) -> Double {
        let own: Double
        switch ink {
        case .cyan: own = cyan
        case .magenta: own = magenta
        case .yellow: own = yellow
        case .black: own = black
        case .spot(let id): own = spots[id] ?? 0
        }
        return max(own, registration)
    }
}
