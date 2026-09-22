import Foundation

/// Identifies a panel: `"object"`, `"layers"`, `"swatches"`.  Stored in layouts, so stable.
struct PanelID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible, Comparable
{
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }

    var description: String { rawValue }

    static func < (lhs: PanelID, rhs: PanelID) -> Bool { lhs.rawValue < rhs.rawValue }
}
