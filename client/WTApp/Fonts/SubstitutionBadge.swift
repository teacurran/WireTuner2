import SwiftUI
import WTText

/// The substitution badge in the Object panel's Character section (font-substitution.adoc, "What
/// happens when a font is missing"; DOC-024): when the text's family is missing on this Mac the
/// section shows the family's name in brackets with a warning badge and the substitute it is drawn
/// in.
extension ObjectPanelModel {
    /// The face drawn in place of the section's family and style, when that family is missing
    /// here; nil when it is available (or the text's families differ).
    func substitute(for section: TextSection) -> FaceName? {
        guard let family = section.family else { return nil }
        let resolution = document.textEngine.fonts.resolve(FaceName(family: family, style: section.style))
        return resolution.source.isSubstitute ? resolution.face : nil
    }
}

struct FontSubstitutionBadge: View {
    let family: String?
    let substitute: FaceName?

    /// "[Futura PT] drawn in Helvetica Neue".
    static func text(family: String, substitute: FaceName) -> String {
        "[\(family)] drawn in \(substitute.family)"
    }

    var body: some View {
        if let family, let substitute {
            Label(Self.text(family: family, substitute: substitute), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("\(family) is missing on this Mac; the text is drawn in \(substitute.description) until it is installed.")
                .accessibilityIdentifier("object.text.substitution")
        }
    }
}
