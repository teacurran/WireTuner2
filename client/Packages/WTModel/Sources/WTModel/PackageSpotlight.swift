import Foundation
import WTCRDT
import WTInterchange

/// What the `WireTunerSpotlightImporter` extension indexes of a package on disk (saving.adoc,
/// "Quick Look and Spotlight" and "Client": Spotlight, packages; IO-035's package half): the
/// manifest's title, and from the snapshot -- decoded with the same zstd and protobuf reader the
/// app opens packages with -- Document Info's description and keywords, the text of every live text
/// node (`SpotlightContent`) and the page count.  A package over `decodeLimit` gives up cleanly
/// with the title alone, so a very large file never stalls the importer.
public struct PackageSpotlightAttributes: Hashable, Sendable {
    /// Packages larger than this are indexed by title only (64 MiB).
    public static let decodeLimit = 64 << 20

    /// `kMDItemTitle`: the manifest's title.
    public var title: String
    /// `kMDItemDescription`, `kMDItemKeywords`, `kMDItemTextContent`.
    public var content: SpotlightContent
    /// `kMDItemNumberOfPages`; nil when the snapshot was not read.
    public var pageCount: Int?

    public init(title: String, content: SpotlightContent = SpotlightContent(), pageCount: Int? = nil) {
        self.title = title
        self.content = content
        self.pageCount = pageCount
    }

    /// Whether only the title was read (the package is over the limit).
    public var isTitleOnly: Bool { pageCount == nil }

    /// The attributes of the package `data`.  Throws when it is not a package this client can
    /// read (the importer then indexes nothing).
    public static func read(_ data: Data, limit: Int = decodeLimit) throws -> PackageSpotlightAttributes {
        let manifest = try PackageReader.manifest(of: data)
        guard data.count <= limit else { return PackageSpotlightAttributes(title: manifest.title) }
        let state = try DocumentPackage.state(of: DocumentPackage.reader.open(data))
        return PackageSpotlightAttributes(title: manifest.title, content: SpotlightContent.of(state), pageCount: PageList(state).pages.count)
    }

    /// The attributes of the package at `url` (memory-mapped).
    public static func read(contentsOf url: URL, limit: Int = decodeLimit) throws -> PackageSpotlightAttributes {
        try read(Data(contentsOf: url, options: .mappedIfSafe), limit: limit)
    }
}
