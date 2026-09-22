/// WTSync: Local store (GRDB), outbox and coalescing, sync client actor, bootstrap, bulk push, divergence measurement, replica rotation, blob queue, presence.
///
/// Placeholder from APP-001; the first task on this package replaces it with real code.
public enum WTSyncPackage {
    /// The package name, as a smoke test that the module links.
    public static let name = "WTSync"

    /// Whether `candidate` names this package, case-insensitively.
    public static func matches(_ candidate: String) -> Bool {
        if candidate.isEmpty {
            return false
        }
        return candidate.lowercased() == name.lowercased()
    }
}
