import Foundation
import WTCRDT
import WTModel
import WTProto

/// A font file embedded in a document: an `asset` under 0:9 whose media type is a font
/// (font-substitution.adoc, "What happens when a font is missing": the second place looked).
struct EmbeddedFont: Hashable, Sendable {
    /// The blob's content hash, lower-case hex.
    let sha256: String
    let mediaType: String

    /// The media types of font files (RFC 8081, and the older names still written).
    static let mediaTypes: Set<String> = [
        "font/ttf", "font/otf", "font/collection", "font/sfnt", "application/font-sfnt", "application/x-font-ttf",
        "application/x-font-otf", "application/x-font-truetype", "application/x-font-opentype",
    ]

    /// The live assets of `state` holding font files, in child order.
    static func all(in state: EngineState) -> [EmbeddedFont] {
        state.liveChildren(WellKnown.assets).compactMap { node in
            guard case .asset(let asset)? = state.props(node).kind,
                  mediaTypes.contains(asset.mediaType.lowercased()), asset.sha256.count == 32 else { return nil }
            return EmbeddedFont(sha256: asset.sha256.map { String(format: "%02x", $0) }.joined(), mediaType: asset.mediaType)
        }
    }
}
