import CryptoKit
import Foundation
import WTCRDT
import WTProto

/// Profile asset nodes (CMS-010, color-profiles.adoc "Data model" and "Merge semantics"): one
/// `profile_asset` node (kind 280) under `assets` (0:9) per custom ICC profile the document
/// carries, so retention, the *Profiles…* list and garbage collection treat profiles like images
/// and fonts.  Referencing registers (`ColorSettings.*_profile`, an image's source profile) hold
/// the `ProfileRef` itself, so an asset that dangles or is deleted never changes rendering: the
/// hash finds the blob.
public enum ProfileAssets {
    /// The `profile_asset` kind (`NodeProps.profile_asset`, CMS block).
    public static let kind: UInt32 = 280
    /// The `assets` collection (0:9).
    public static let assets = OpID.wellKnown(9)
    static let profileRef = "wiretuner.doc.v1.ProfileRef"

    /// One row of the *Profiles…* sheet: the live asset nodes of one hash, presented as one (two
    /// replicas choosing the same profile at once make two nodes).
    public struct Entry: Hashable, Sendable, Identifiable {
        public var sha256: Data
        public var name: String
        public var space: Wiretuner_Doc_V1_ProfileSpace
        public var size: UInt64
        /// The nodes holding it, ascending.
        public var nodes: [OpID]
        /// Whether anything in the document references the profile now.
        public var isReferenced: Bool
        public var id: Data { sha256 }
    }

    /// The *Profiles…* list: the live profile assets de-duplicated by hash, by name.
    public static func list(_ state: EngineState) -> [Entry] {
        let referenced = referencedHashes(in: state)
        var byHash: [Data: Entry] = [:]
        for node in state.liveChildren(assets) where state.store.kind(node) == kind {
            let props = state.props(node).profileAsset
            let hash = props.profile.sha256
            guard hash.count == 32 else { continue }
            if var entry = byHash[hash] {
                entry.nodes.append(node)
                byHash[hash] = entry
            } else {
                byHash[hash] = Entry(sha256: hash, name: props.profile.name, space: props.profile.space, size: props.size, nodes: [node],
                                     isReferenced: referenced.contains(hash))
            }
        }
        return byHash.values.map { entry in
            var sorted = entry
            sorted.nodes.sort()
            return sorted
        }.sorted { lhs, rhs in
            lhs.name.lowercased() != rhs.name.lowercased() ? lhs.name.lowercased() < rhs.name.lowercased() : lhs.sha256.lexicographicallyPrecedes(rhs.sha256)
        }
    }

    /// The live asset node holding `sha256` (the smallest id), if any.
    public static func asset(for sha256: Data, in state: EngineState) -> OpID? {
        state.liveChildren(assets).filter { state.store.kind($0) == kind && state.props($0).profileAsset.profile.sha256 == sha256 }.min()
    }

    /// Whether a profile needs an asset: a custom (non-bundled) profile with a hash.
    public static func isCustom(_ profile: Wiretuner_Doc_V1_ProfileRef) -> Bool {
        profile.bundledID.isEmpty && profile.sha256.count == 32
    }

    /// The assets one change creates so far.
    struct Pending {
        var nodes: [Data: OpID] = [:]
        var lastKey: [UInt8]?
    }

    /// Appends the creation of an asset for `profile` unless it is bundled or a live asset of its
    /// hash exists (or one was created earlier in this change, `pending`); returns the asset.
    @discardableResult
    static func ensure(_ profile: Wiretuner_Doc_V1_ProfileRef, size: UInt64, state: EngineState, pending: inout Pending,
                       builder: inout ChangeBuilder) throws -> OpID? {
        guard isCustom(profile) else { return nil }
        if let existing = pending.nodes[profile.sha256] ?? asset(for: profile.sha256, in: state) { return existing }
        let last = pending.lastKey ?? state.store.children(assets).last.flatMap { state.store.placement($0)?.position }
        let key = try PathEditing.keys(between: last, and: nil, count: 1)[0]
        var props = Wiretuner_Doc_V1_NodeProps()
        props.profileAsset.profile = profile
        props.profileAsset.size = size
        let node = builder.append(Ops.create(parent: assets, position: key, props: props))
        pending.nodes[profile.sha256] = node
        pending.lastKey = key
        return node
    }

    /// The profiles `props` holds anywhere (every `ProfileRef` field, at any depth).
    public static func profiles(in props: Wiretuner_Doc_V1_NodeProps, schema: Schema) -> [Wiretuner_Doc_V1_ProfileRef] {
        var out: [Wiretuner_Doc_V1_ProfileRef] = []
        collect(Schema.root, Wire.bytes { try props.serializedBytes() }, schema: schema, into: &out)
        return out
    }

    private static func collect(_ message: String, _ bytes: [UInt8], schema: Schema, into out: inout [Wiretuner_Doc_V1_ProfileRef]) {
        guard let fields = WireReader.fields(bytes) else { return }
        for field in fields where field.wireType == 2 {
            guard let type = schema.field(message, Int(field.number))?.typeName else { continue }
            if type == profileRef {
                if let profile = try? Wiretuner_Doc_V1_ProfileRef(serializedBytes: field.payload) { out.append(profile) }
            } else if !schema.fields(type).isEmpty {
                collect(type, field.payload, schema: schema, into: &out)
            }
        }
    }

    /// Every custom profile hash a live node other than a profile asset references.
    public static func referencedHashes(in state: EngineState) -> Set<Data> {
        var out: Set<Data> = []
        for node in state.store.nodes where state.isLive(node) && state.store.kind(node) != kind {
            for profile in profiles(in: state.props(node), schema: state.schema) where isCustom(profile) {
                out.insert(profile.sha256)
            }
        }
        return out
    }

    /// The live assets nothing references now.
    public static func unreferenced(in state: EngineState) -> [OpID] {
        let referenced = referencedHashes(in: state)
        return state.liveChildren(assets).filter { node in
            state.store.kind(node) == kind && !referenced.contains(state.props(node).profileAsset.profile.sha256)
        }
    }

    /// *Profiles…* btn:[Export…]: the profile's bytes from the blob cache, checked against the
    /// asset's hash (nil when they do not match, or the asset is not a profile).
    public static func exportData(_ asset: OpID, blob: Data, in state: EngineState) -> Data? {
        guard state.store.kind(asset) == kind, Data(SHA256.hash(data: blob)) == state.props(asset).profileAsset.profile.sha256 else { return nil }
        return blob
    }
}

/// Creates the asset nodes for custom profiles chosen or extracted from an image (the profile
/// menus' *Installed* and *Other…*, an image's embedded profile): one node per hash not already
/// carried, one change "Add profile" / "Add N profiles".  Choosing the profile itself is the
/// command writing the referencing register (`ChangeColorSettings`, which also creates the asset).
public struct AddProfileAssets: Command {
    public var profiles: [(profile: Wiretuner_Doc_V1_ProfileRef, size: UInt64)]
    public var label: String { profiles.count == 1 ? "Add profile" : "Add \(profiles.count) profiles" }

    public init(_ profiles: [(profile: Wiretuner_Doc_V1_ProfileRef, size: UInt64)]) {
        self.profiles = profiles
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var pending = ProfileAssets.Pending()
        for (profile, size) in profiles {
            try ProfileAssets.ensure(profile, size: size, state: state, pending: &pending, builder: &builder)
        }
    }
}

/// The reference scan (color-profiles.adoc, "Merge semantics"): a client marks a profile asset
/// deleted once nothing in the merged state has referenced its hash for the deleted-node
/// compaction window.  The scan remembers on this Mac when each asset was first seen
/// unreferenced; a reference seen again resets it.  Nothing is written by the scan itself.
public struct ProfileReferenceScan: Hashable, Sendable {
    /// Asset → when it was first seen unreferenced (ms since 1970).
    public private(set) var unreferencedSince: [OpID: Int64] = [:]
    /// How long an asset stays unreferenced before it is marked deleted.
    public var window: Int64

    public init(window: Int64 = EngineState.deletedNodeRetentionMs) {
        self.window = window
    }

    /// Scans `state` at `now` and returns the assets due to be marked deleted.
    public mutating func observe(_ state: EngineState, now: Int64) -> [OpID] {
        let unreferenced = Set(ProfileAssets.unreferenced(in: state))
        unreferencedSince = unreferencedSince.filter { unreferenced.contains($0.key) }
        for asset in unreferenced where unreferencedSince[asset] == nil {
            unreferencedSince[asset] = now
        }
        return unreferencedSince.filter { now - $0.value >= window }.keys.sorted()
    }
}

/// Marks the unreferenced profile assets deleted (the scan's result, re-checked against the state
/// the change is built on: an asset referenced again meanwhile is kept).  Not an undo step: it is
/// housekeeping, not something the user did.  "Remove unused profiles".
public struct RemoveUnreferencedProfiles: Command {
    public var assets: [OpID]
    public var label: String { "Remove unused profiles" }
    public var recordsUndo: Bool { false }

    public init(_ assets: [OpID]) {
        self.assets = assets
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let unreferenced = Set(ProfileAssets.unreferenced(in: state))
        for asset in assets.sorted() where unreferenced.contains(asset) {
            builder.append(Ops.setDeleted(asset))
        }
    }
}
