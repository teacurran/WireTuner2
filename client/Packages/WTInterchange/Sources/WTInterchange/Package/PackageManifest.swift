// `PackageManifest` (saving.adoc, "Data model"; D-038), the package's `manifest.json`, in the
// protobuf JSON mapping: lowerCamelCase keys, 64-bit integers as strings, bytes as base64, fields
// at their default value omitted.  The reader also accepts the proto field names and numbers
// written as JSON numbers, as every protobuf JSON parser must.  The message is defined here rather
// than generated from `docs/v1/package.proto` because that file has not been added to `proto/`
// yet (the package is never merged, so no merge table is involved); the JSON is byte-compatible
// with what swift-protobuf will write once it is.

import Foundation

/// One blob listed in the manifest.
public struct PackageBlob: Hashable, Sendable {
    /// SHA-256, 32 bytes.
    public var sha256: Data
    public var size: UInt64
    /// `image/png`, `font/otf`, …
    public var mediaType: String
    /// The asset node's display name, informational.
    public var name: String

    public init(sha256: Data, size: UInt64, mediaType: String, name: String = "") {
        self.sha256 = sha256
        self.size = size
        self.mediaType = mediaType
        self.name = name
    }

    /// The hash as the entry name's hex (`blobs/<hex>`).
    public var hex: String { ImportedBlob.hex(sha256) }
}

/// The package manifest.
public struct PackageManifest: Hashable, Sendable {
    /// `format` of every package.
    public static let formatName = "wiretuner-package"
    /// The version this client writes and reads.
    public static let currentFormatVersion: UInt32 = 1

    public var format: String
    public var formatVersion: UInt32
    /// UUIDv7 of the document this was exported from.
    public var originDocumentID: String
    public var title: String
    public var exportedBy: String
    public var exportedByName: String
    public var exportedAtMs: Int64
    public var appVersion: String
    /// The document's feature level; importers below it refuse.
    public var featureLevel: UInt32
    /// The merge table version the snapshot was written with.
    public var mergeTableVersion: UInt32
    public var headServerSeq: UInt64
    /// Local changes not acked when exported; 0 = clean.
    public var unsyncedChanges: UInt32
    /// `StateHash` of the snapshot's state (crdt-model.adoc, "Snapshots").
    public var stateHash: Data
    public var blobs: [PackageBlob]
    /// Referenced but not in the local cache at export.
    public var missingBlobs: [PackageBlob]

    public init(format: String = PackageManifest.formatName, formatVersion: UInt32 = PackageManifest.currentFormatVersion, originDocumentID: String = "", title: String = "", exportedBy: String = "", exportedByName: String = "", exportedAtMs: Int64 = 0, appVersion: String = "", featureLevel: UInt32 = 0, mergeTableVersion: UInt32 = 0, headServerSeq: UInt64 = 0, unsyncedChanges: UInt32 = 0, stateHash: Data = Data(), blobs: [PackageBlob] = [], missingBlobs: [PackageBlob] = []) {
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
        var fields: [(String, String)] = []
        func string(_ key: String, _ value: String) {
            if !value.isEmpty { fields.append((key, PackageManifest.quote(value))) }
        }
        func number<T: BinaryInteger>(_ key: String, _ value: T, quoted: Bool = false) {
            if value != 0 { fields.append((key, quoted ? "\"\(value)\"" : "\(value)")) }
        }
        string("format", format)
        number("formatVersion", formatVersion)
        string("originDocumentId", originDocumentID)
        string("title", title)
        string("exportedBy", exportedBy)
        string("exportedByName", exportedByName)
        number("exportedAtMs", exportedAtMs, quoted: true)
        string("appVersion", appVersion)
        number("featureLevel", featureLevel)
        number("mergeTableVersion", mergeTableVersion)
        number("headServerSeq", headServerSeq, quoted: true)
        number("unsyncedChanges", unsyncedChanges)
        if !stateHash.isEmpty {
            fields.append(("stateHash", PackageManifest.quote(stateHash.base64EncodedString())))
        }
        if !blobs.isEmpty {
            fields.append(("blobs", "[" + blobs.map(PackageManifest.json).joined(separator: ",") + "]"))
        }
        if !missingBlobs.isEmpty {
            fields.append(("missingBlobs", "[" + missingBlobs.map(PackageManifest.json).joined(separator: ",") + "]"))
        }
        return Data(("{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}").utf8)
    }

    static func json(_ blob: PackageBlob) -> String {
        var fields: [String] = []
        if !blob.sha256.isEmpty { fields.append("\"sha256\":" + quote(blob.sha256.base64EncodedString())) }
        if blob.size != 0 { fields.append("\"size\":\"\(blob.size)\"") }
        if !blob.mediaType.isEmpty { fields.append("\"mediaType\":" + quote(blob.mediaType)) }
        if !blob.name.isEmpty { fields.append("\"name\":" + quote(blob.name)) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// `value` as a JSON string literal.
    static func quote(_ value: String) -> String {
        // JSONSerialization escapes exactly what JSON requires; wrap in an array to encode a
        // bare string and strip the brackets.
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    /// Parses protobuf JSON: either key spelling, integers as numbers or strings.
    public init(jsonData data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data), let fields = object as? [String: Any] else {
            throw PackageError.malformedManifest("it is not a JSON object")
        }
        let reader = PackageManifest.FieldReader(fields: fields)
        self.init(
            format: try reader.string("format"),
            formatVersion: try reader.integer("formatVersion", "format_version"),
            originDocumentID: try reader.string("originDocumentId", "origin_document_id"),
            title: try reader.string("title"),
            exportedBy: try reader.string("exportedBy", "exported_by"),
            exportedByName: try reader.string("exportedByName", "exported_by_name"),
            exportedAtMs: try reader.integer("exportedAtMs", "exported_at_ms"),
            appVersion: try reader.string("appVersion", "app_version"),
            featureLevel: try reader.integer("featureLevel", "feature_level"),
            mergeTableVersion: try reader.integer("mergeTableVersion", "merge_table_version"),
            headServerSeq: try reader.integer("headServerSeq", "head_server_seq"),
            unsyncedChanges: try reader.integer("unsyncedChanges", "unsynced_changes"),
            stateHash: try reader.bytes("stateHash", "state_hash"),
            blobs: try reader.blobs("blobs"),
            missingBlobs: try reader.blobs("missingBlobs", "missing_blobs"))
    }

    /// Typed access to a decoded JSON object's fields.
    struct FieldReader {
        var fields: [String: Any]

        func value(_ keys: [String]) -> Any? {
            for key in keys {
                if let value = fields[key], !(value is NSNull) {
                    return value
                }
            }
            return nil
        }

        func string(_ keys: String...) throws -> String {
            guard let value = value(keys) else { return "" }
            guard let string = value as? String else {
                throw PackageError.malformedManifest("“\(keys[0])” is not a string")
            }
            return string
        }

        func integer<T: FixedWidthInteger>(_ keys: String...) throws -> T {
            guard let value = value(keys) else { return 0 }
            if let string = value as? String, let number = T(string) {
                return number
            }
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let exact = T(exactly: number.doubleValue) {
                return exact
            }
            throw PackageError.malformedManifest("“\(keys[0])” is not an integer")
        }

        func bytes(_ keys: String...) throws -> Data {
            guard let value = value(keys) else { return Data() }
            // Protobuf JSON parsers accept standard and URL-safe base64, padded or not.
            guard let string = value as? String, let data = Data(base64Encoded: PackageManifest.standardBase64(string)) else {
                throw PackageError.malformedManifest("“\(keys[0])” is not base64")
            }
            return data
        }

        func blobs(_ keys: String...) throws -> [PackageBlob] {
            guard let value = value(keys) else { return [] }
            guard let list = value as? [[String: Any]] else {
                throw PackageError.malformedManifest("“\(keys[0])” is not a list of blobs")
            }
            return try list.map { fields in
                let reader = FieldReader(fields: fields)
                return PackageBlob(sha256: try reader.bytes("sha256"), size: try reader.integer("size"), mediaType: try reader.string("mediaType", "media_type"), name: try reader.string("name"))
            }
        }
    }

    /// URL-safe or unpadded base64 as standard padded base64.
    static func standardBase64(_ string: String) -> String {
        var text = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 {
            text += "="
        }
        return text
    }
}
