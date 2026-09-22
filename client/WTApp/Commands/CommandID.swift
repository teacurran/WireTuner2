import Foundation

/// Identifies a command in the registry: `"file.new"`, `"view.zoomIn"`, `"panel.show.layers"`.
/// The string is stable across launches because shortcut sets, the palette history and
/// accessibility identifiers (`menu.<id>`) all refer to commands by it.
struct CommandID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible, Comparable
{
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }

    var description: String { rawValue }

    static func < (lhs: CommandID, rhs: CommandID) -> Bool { lhs.rawValue < rhs.rawValue }
}
