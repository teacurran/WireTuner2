/// WTModel: The typed document: `Document`, `Node` wrappers per kind, `Command`s that produce `Change`s, selection, normalize-on-read views, validators.
///
/// Placeholder from APP-001; the first task on this package replaces it with real code.
public enum WTModelPackage {
    /// The package name, as a smoke test that the module links.
    public static let name = "WTModel"

    /// Whether `candidate` names this package, case-insensitively.
    public static func matches(_ candidate: String) -> Bool {
        if candidate.isEmpty {
            return false
        }
        return candidate.lowercased() == name.lowercased()
    }
}
