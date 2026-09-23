import Foundation
import WTRender

/// The app's side of WTRender's drawing modes (document-view.adoc, "Drawing modes"): the
/// titles the status bar and menus show, and the `DrawingMode` spelling window state stores
/// (`preview`, `fast_preview`, `keyline`, `fast_keyline`), which files written before REND-005
/// already use.
extension ViewMode {
    var title: String {
        switch self {
        case .preview: "Preview"
        case .fastPreview: "Fast Preview"
        case .keyline: "Keyline"
        case .fastKeyline: "Fast Keyline"
        }
    }

    /// The stored name (`DrawingMode` in `doc/v1/view.proto`, lower snake case).
    var storedName: String {
        switch self {
        case .preview: "preview"
        case .fastPreview: "fast_preview"
        case .keyline: "keyline"
        case .fastKeyline: "fast_keyline"
        }
    }

    init?(storedName: String) {
        guard let mode = ViewMode.allCases.first(where: { $0.storedName == storedName }) else { return nil }
        self = mode
    }
}

extension ViewMode: @retroactive Codable {
    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let mode = ViewMode(storedName: name) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "unknown drawing mode \(name)"))
        }
        self = mode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storedName)
    }
}
