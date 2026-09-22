/// WTTestSupport: Simulated clients, vector loaders, screenshot helpers.
///
/// Placeholder from APP-001; the first task on this package replaces it with real code.
public enum WTTestSupportPackage {
    /// The package name, as a smoke test that the module links.
    public static let name = "WTTestSupport"

    /// Whether `candidate` names this package, case-insensitively.
    public static func matches(_ candidate: String) -> Bool {
        if candidate.isEmpty {
            return false
        }
        return candidate.lowercased() == name.lowercased()
    }
}
