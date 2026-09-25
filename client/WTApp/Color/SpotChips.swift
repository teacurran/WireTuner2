import AppKit
import WTCRDT
import WTModel
import WTProto
import WTRender

/// The Swatches panel's spot chips (color-tables.adoc, "Spot color libraries"; the WTApp half of
/// CMS-014): a spot swatch from a library is previewed through one app-wide `WTColor.SpotLibraryStore` --
/// its ink's measured Lab into Working RGB while *Color manage spot colors* is on, its nominal CMYK
/// otherwise -- and marked "library not available" when this app lacks the library or ink.  A tint
/// of it previews its base's ink at the tint's strength.  Toggling the setting re-renders the chips
/// and writes nothing.
@MainActor
enum SpotChips {
    /// The app's store: the bundled `SpotLibraries` resources and the built-in development library.
    static var store = WTColor.SpotLibraryStore(directory: Bundle.main.url(forResource: "SpotLibraries", withExtension: nil))

    static let unavailable = "Library not available"

    /// The preview settings of `state`'s colour settings.
    static func settings(_ state: EngineState) -> WTColor.SpotPreviewSettings {
        let color = ColorSettings(state)
        return WTColor.SpotPreviewSettings(managed: color.spotColorManagement, rgbProfile: color.rgbProfile, cmykProfile: color.cmykProfile, intent: color.intent)
    }

    /// The library swatch a spot swatch previews (itself, or a tint's base) and the tint's strength.
    static func source(_ swatch: Swatch, in list: SwatchList) -> (swatch: Swatch, tint: Double)? {
        guard swatch.isSpot else { return nil }
        var current = swatch
        var tint = 1.0
        var seen: Set<OpID> = [swatch.id]
        while current.props.library.isEmpty, let base = current.base.flatMap({ list[$0] }), seen.insert(base.id).inserted {
            tint *= current.tintPercent / 100
            current = base
        }
        return current.props.library.isEmpty ? nil : (current, tint)
    }

    /// The preview of a library spot swatch; nil for any other swatch.
    static func preview(_ swatch: Swatch, in list: SwatchList, settings: WTColor.SpotPreviewSettings) -> WTColor.SpotPreview? {
        guard let (source, tint) = source(swatch, in: list) else { return nil }
        let nominal = source.color.converted(to: .cmyk).components
        return store.previewColor(library: source.props.library, ink: source.props.libraryKey.isEmpty ? source.plainName : source.props.libraryKey,
                                  nominal: nominal, tint: tint, settings: settings)
    }
}

extension SwatchesPanelModel {
    /// The chip a swatch shows: a library spot's preview, else its colour.
    func chipColor(_ swatch: Swatch) -> RenderColor {
        guard let list, let state = workspace.document?.state,
              let preview = SpotChips.preview(swatch, in: list, settings: SpotChips.settings(state)) else { return swatch.color }
        return preview.color
    }

    /// Whether the swatch names a spot library or ink this app does not have.
    func libraryMissing(_ swatch: Swatch) -> Bool {
        guard let list, let state = workspace.document?.state,
              let preview = SpotChips.preview(swatch, in: list, settings: SpotChips.settings(state)) else { return false }
        return !preview.libraryAvailable
    }
}
