// `PackageManifest` (saving.adoc, "Data model"; D-038), the package's `manifest.json`: the
// generated `wiretuner.docs.v1.PackageManifest` (proto/wiretuner/docs/v1/package.proto) in the
// protobuf JSON mapping, written and read by SwiftProtobuf -- lowerCamelCase keys, 64-bit
// integers as strings, bytes as base64, fields at their default value omitted; on read either
// key spelling, integers as numbers or strings, standard or URL-safe base64, and unknown fields
// ignored (a later client may add some without changing `format_version`).  The package is never
// merged, so no merge table is involved.

import Foundation
import SwiftProtobuf
import WTProto

/// The package manifest.
public typealias PackageManifest = Wiretuner_Docs_V1_PackageManifest

/// One blob listed in the manifest.
public typealias PackageBlob = Wiretuner_Docs_V1_PackageBlob

extension Wiretuner_Docs_V1_PackageBlob {
    public init(sha256: Data, size: UInt64, mediaType: String, name: String = "") {
        self.init()
        self.sha256 = sha256
        self.size = size
        self.mediaType = mediaType
        self.name = name
    }

    /// The hash as the entry name's hex (`blobs/<hex>`).
    public var hex: String { ImportedBlob.hex(sha256) }
}

extension Wiretuner_Docs_V1_PackageManifest {
    /// `format` of every package.
    public static let formatName = "wiretuner-package"
    /// The version this client writes and reads.
    public static let currentFormatVersion: UInt32 = 1

    public init(format: String = formatName, formatVersion: UInt32 = currentFormatVersion, originDocumentID: String = "", title: String = "", exportedBy: String = "", exportedByName: String = "", exportedAtMs: Int64 = 0, appVersion: String = "", featureLevel: UInt32 = 0, mergeTableVersion: UInt32 = 0, headServerSeq: UInt64 = 0, unsyncedChanges: UInt32 = 0, stateHash: Data = Data(), blobs: [PackageBlob] = [], missingBlobs: [PackageBlob] = []) {
        self.init()
        self.format = format
        self.formatVersion = formatVersion
        self.originDocumentID = originDocumentID
        self.title = title
        self.exportedBy = exportedBy
        self.exportedByName = exportedByName
        self.exportedAtMs = exportedAtMs
        self.appVersion = appVersion
        self.featureLevel = featureLevel
        self.mergeTableVersion = mergeTableVersion
        self.headServerSeq = headServerSeq
        self.unsyncedChanges = unsyncedChanges
        self.stateHash = stateHash
        self.blobs = blobs
        self.missingBlobs = missingBlobs
    }

    // MARK: JSON

    /// The manifest in protobuf JSON, keys in field-number order.
    public func jsonData() -> Data {
        // Encoding fails only for `Any` fields without a registry; the manifest has none.
        // swiftlint:disable:next force_try
        try! jsonUTF8Data()
    }

    /// Parses protobuf JSON: either key spelling, integers as numbers or strings, unknown
    /// fields ignored.
    public init(jsonData data: Data) throws {
        var options = JSONDecodingOptions()
        options.ignoreUnknownFields = true
        do {
            try self.init(jsonUTF8Data: data, options: options)
        } catch {
            throw PackageError.malformedManifest("it is not a protobuf JSON PackageManifest (\(error))")
        }
    }
}
