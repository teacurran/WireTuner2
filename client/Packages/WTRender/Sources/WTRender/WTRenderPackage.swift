/// WTRender: Display list, the Metal tile renderer, the Core Graphics reference renderer, tile cache and view transform, hit testing, invalidation, view modes, glyph atlas.
///
/// Placeholder from APP-001; the first task on this package replaces it with real code.
public enum WTRenderPackage {
    /// The package name, as a smoke test that the module links.
    public static let name = "WTRender"

    /// Whether `candidate` names this package, case-insensitively.
    public static func matches(_ candidate: String) -> Bool {
        if candidate.isEmpty {
            return false
        }
        return candidate.lowercased() == name.lowercased()
    }
}
