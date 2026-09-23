/// WTTestSupport: Simulated clients, vector loaders, screenshot helpers.  The multi-client
/// simulator (TEST-001) is `Simulation` and its parts under `Simulation/`.
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
