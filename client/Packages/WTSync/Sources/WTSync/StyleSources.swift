import Foundation
import WTCRDT
import WTModel

/// Where *Import…* and *Export…* in the Styles panel read and write styles (styles.adoc, "Copying
/// styles between documents"; LIB-022): another document's state comes from `SymbolSources` (its
/// local store, offline too, or the server at head), a team library's from `TeamLibraryClient`,
/// and a style library file is read by `StylePackage(fileData:)`.  Writing a file fills the
/// package's asset bytes from the blob cache here; reading one puts them into it.
public enum StyleSources {
    /// The package of `styles` (every live graphic style when nil) in `state`; with `cache`, the
    /// bytes of the assets it needs that are cached here.
    public static func package(of state: EngineState, styles: [OpID]? = nil, cache: BlobCache? = nil) -> StylePackage {
        var package = styles.map { StylePackage(styles: $0, from: state) } ?? StylePackage(allStylesOf: state)
        if let cache {
            for hash in package.assetHashes {
                if let data = try? Data(contentsOf: cache.url(for: hash)) { package.blobs[hash] = data }
            }
        }
        return package
    }

    /// Puts a style library file's asset bytes into `cache`; returns the hashes stored.
    @discardableResult
    public static func storeBlobs(of package: StylePackage, in cache: BlobCache) throws -> [String] {
        try SymbolSources.storeBlobs(of: SymbolPackage(blobs: package.blobs), in: cache)
    }
}
