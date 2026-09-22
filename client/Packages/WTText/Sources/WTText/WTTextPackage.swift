/// WTText: Core Text layout over `RichText`, fonts, substitution, text on a path, vertical text.
///
/// Placeholder from APP-001; the first task on this package replaces it with real code.
public enum WTTextPackage {
    /// The package name, as a smoke test that the module links.
    public static let name = "WTText"

    /// Whether `candidate` names this package, case-insensitively.
    public static func matches(_ candidate: String) -> Bool {
        if candidate.isEmpty {
            return false
        }
        return candidate.lowercased() == name.lowercased()
    }
}
