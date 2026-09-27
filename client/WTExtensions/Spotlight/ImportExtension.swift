import CoreSpotlight
import Foundation

/// The Core Spotlight import extension for `.wiretuner` packages (IO-035): sandboxed, no network;
/// it reads the package through `WTModel` (`SpotlightImport`).
final class ImportExtension: CSImportExtension {
    override func update(_ attributes: CSSearchableItemAttributeSet, forFileAt contentURL: URL) throws {
        try SpotlightImport.update(attributes, forFileAt: contentURL)
    }
}
