import CoreSpotlight
import Foundation
import WTModel

/// What the `WireTunerSpotlightImporter` extension writes for a `.wiretuner` package on disk
/// (saving.adoc, "Quick Look and Spotlight" and "Client": Spotlight, packages; IO-035): the
/// attributes `PackageSpotlightAttributes` reads, onto `kMDItemTitle`, `kMDItemDisplayName`,
/// `kMDItemDescription`, `kMDItemKeywords`, `kMDItemTextContent` and `kMDItemNumberOfPages`.
/// Compiled into the app as well, so the app's tests cover it.
enum SpotlightImport {
    /// Fills `set` from the package at `url`; throws when it is not a package this client reads.
    static func update(_ set: CSSearchableItemAttributeSet, forFileAt url: URL,
                       limit: Int = PackageSpotlightAttributes.decodeLimit) throws {
        apply(try PackageSpotlightAttributes.read(contentsOf: url, limit: limit), to: set)
    }

    /// Writes `attributes` onto `set`: empty values stay unset, a title-only read sets no page count.
    static func apply(_ attributes: PackageSpotlightAttributes, to set: CSSearchableItemAttributeSet) {
        set.title = attributes.title
        set.displayName = attributes.title
        let content = attributes.content
        set.contentDescription = content.description.isEmpty ? nil : content.description
        set.keywords = content.keywords.isEmpty ? nil : content.keywords
        set.textContent = content.text.isEmpty ? nil : content.text
        set.pageCount = attributes.pageCount.map { NSNumber(value: $0) }
    }
}
