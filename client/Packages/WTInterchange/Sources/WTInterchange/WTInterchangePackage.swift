/// WTInterchange: Importers and exporters (SVG, PDF, EPS, AI, PSD, images, RTF, UFO/OTF), the `.wiretuner` package, printing.
///
/// Placeholder from APP-001; the first task on this package replaces it with real code.
public enum WTInterchangePackage {
    /// The package name, as a smoke test that the module links.
    public static let name = "WTInterchange"

    /// Whether `candidate` names this package, case-insensitively.
    public static func matches(_ candidate: String) -> Bool {
        if candidate.isEmpty {
            return false
        }
        return candidate.lowercased() == name.lowercased()
    }
}
