/// WTCRDT: The merge engine: `Engine` actor, node store, registers, move log, Fugue text, marks, fractional index, snapshot codec, state hash.
///
/// Placeholder from APP-001; the first task on this package replaces it with real code.
public enum WTCRDTPackage {
    /// The package name, as a smoke test that the module links.
    public static let name = "WTCRDT"

    /// Whether `candidate` names this package, case-insensitively.
    public static func matches(_ candidate: String) -> Bool {
        if candidate.isEmpty {
            return false
        }
        return candidate.lowercased() == name.lowercased()
    }
}
