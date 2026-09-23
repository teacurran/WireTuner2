// The profile registry (CMS-002; docs/_includes/cms/color-management.adoc and
// color-profiles.adoc): every `ProfileRef` resolves to ICC data and a `CGColorSpace`, cached by
// SHA-256.  Bundled profiles come from ColorSync's system profiles, loaded once per process;
// custom profiles arrive as blobs (CMS-008) through `blobLoader` or are registered from ICC
// data; installed profiles are enumerated through `ColorSyncIterateInstalledProfiles`.

@preconcurrency import ColorSync
import CoreGraphics
import CryptoKit
import Foundation

extension WTColor {
    /// The class of colour a profile describes (`ProfileSpace`).
    public enum ProfileSpace: Hashable, Sendable, CaseIterable {
        case rgb
        case cmyk
        case gray
        case lab

        /// The space of an ICC header's data colour space signature, if it is one of ours.
        init?(signature: String) {
            switch signature.trimmingCharacters(in: .whitespaces) {
            case "RGB": self = .rgb
            case "CMYK": self = .cmyk
            case "GRAY": self = .gray
            case "Lab": self = .lab
            default: return nil
            }
        }

        /// The number of device channels.
        public var channelCount: Int {
            switch self {
            case .cmyk: return 4
            case .gray: return 1
            case .rgb, .lab: return 3
            }
        }
    }

    /// Identifies one ICC profile (`ProfileRef`): the description, the SHA-256 of the bytes,
    /// the bundled id for a profile shipped with the app (empty otherwise) and the space.
    public struct ProfileRef: Hashable, Sendable, CustomStringConvertible {
        public var name: String
        public var sha256: Data
        public var bundledID: String
        public var space: ProfileSpace

        public init(name: String, sha256: Data, bundledID: String = "", space: ProfileSpace) {
            self.name = name
            self.sha256 = sha256
            self.bundledID = bundledID
            self.space = space
        }

        /// Whether the profile ships with the app (readers never fetch a blob for it).
        public var isBundled: Bool { !bundledID.isEmpty }

        /// The hash in lowercase hex: the blob id of a custom profile.
        public var hexHash: String { sha256.map { String(format: "%02x", $0) }.joined() }

        public var description: String { bundledID.isEmpty ? "\(name) [\(hexHash.prefix(12))]" : "\(name) (\(bundledID))" }
    }

    /// An installed profile found by `ProfileRegistry.installedProfiles`.
    public struct InstalledProfile: Hashable, Sendable {
        public var name: String
        public var url: URL
        public var space: ProfileSpace
        /// The ICC profile class signature (`mntr`, `prtr`, `scnr`, `spac`).
        public var profileClass: String
    }

    /// Resolves profiles to ICC data and `CGColorSpace`s.  Thread-safe.
    public final class ProfileRegistry: @unchecked Sendable {
        /// The bundled ids, in menu order.
        public static let bundledIDs = ["srgb", "display-p3", "generic-gray", "default-cmyk"]

        /// The process-wide registry.
        public static let shared = ProfileRegistry()

        /// Fetches a custom profile's bytes by SHA-256 from the blob cache (CMS-008); nil while
        /// the blob is not local, which renders through the bundled fallback with `pending`.
        public var blobLoader: (@Sendable (Data) -> Data?)? {
            get { lock.withLock { loader } }
            set { lock.withLock { loader = newValue } }
        }

        private let lock = NSLock()
        private var loader: (@Sendable (Data) -> Data?)?
        private var dataByHash: [Data: Data] = [:]
        private var spaceByHash: [Data: CGColorSpace] = [:]
        private var bundledByID: [String: ProfileRef] = [:]
        /// Normalized hash (header fields that do not change the colours zeroed) → bundled id.
        private var bundledByNormalizedHash: [Data: String] = [:]

        public init() {
            let sources: [(String, CFString)] = [
                ("srgb", CGColorSpace.sRGB),
                ("display-p3", CGColorSpace.displayP3),
                ("generic-gray", CGColorSpace.genericGrayGamma2_2),
                ("default-cmyk", CGColorSpace.genericCMYK),
            ]
            for (id, name) in sources {
                // Every name above is a system ICC-based space: none of these unwrap nil.
                let space = CGColorSpace(name: name)!
                let data = space.copyICCData()! as Data
                let hash = ProfileRegistry.hash(data)
                var ref = ProfileRegistry.makeRef(iccData: data)!
                ref.bundledID = id
                bundledByID[id] = ref
                dataByHash[hash] = data
                spaceByHash[hash] = space
                bundledByNormalizedHash[ProfileRegistry.normalizedHash(data)] = id
            }
        }

        // MARK: Bundled

        /// The bundled profile with `id`.
        public func bundled(_ id: String) -> ProfileRef? {
            lock.withLock { bundledByID[id] }
        }

        /// Every bundled profile, in menu order.
        public var bundledProfiles: [ProfileRef] {
            ProfileRegistry.bundledIDs.compactMap { bundled($0) }
        }

        public var sRGB: ProfileRef { bundled("srgb")! }
        public var displayP3: ProfileRef { bundled("display-p3")! }
        public var genericGray: ProfileRef { bundled("generic-gray")! }
        public var defaultCMYK: ProfileRef { bundled("default-cmyk")! }

        /// The bundled default of `space` a missing profile renders through
        /// (color-management.adoc, "Read-time normalizations"); Lab has none of its own and
        /// falls back to sRGB.
        public func fallback(for space: ProfileSpace) -> ProfileRef {
            switch space {
            case .cmyk: return defaultCMYK
            case .gray: return genericGray
            case .rgb, .lab: return sRGB
            }
        }

        // MARK: Refs from data

        /// SHA-256 of `data`.
        public static func hash(_ data: Data) -> Data {
            Data(SHA256.hash(data: data))
        }

        /// SHA-256 of `data` with the ICC header fields that do not affect colours zeroed
        /// (flags, rendering intent and profile id, the fields the ICC profile id itself
        /// ignores), so an embedded copy of a bundled profile saved with another intent is
        /// still recognized.
        static func normalizedHash(_ data: Data) -> Data {
            var bytes = [UInt8](data)
            for range in [44..<48, 64..<68, 84..<100] where bytes.count >= range.upperBound {
                for index in range {
                    bytes[index] = 0
                }
            }
            return hash(Data(bytes))
        }

        /// A `ProfileRef` for ICC `data`: its description tag, hash and space; nil for data
        /// ColorSync cannot read or whose space is not RGB, CMYK, gray or Lab.  The bundled id
        /// is left empty (see `register`).
        public static func makeRef(iccData data: Data) -> ProfileRef? {
            guard data.count >= 128,
                  let profile = ColorSyncProfileCreate(data as CFData, nil)?.takeRetainedValue(),
                  let space = ProfileSpace(signature: String(decoding: data[16..<20], as: UTF8.self))
            else {
                return nil
            }
            let name = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String? ?? "Untitled Profile"
            return ProfileRef(name: name, sha256: hash(data), space: space)
        }

        /// Registers ICC `data` (a custom profile loaded from a file, a blob, an image's
        /// embedded profile) and returns its ref, recognizing a bundled profile by hash; nil
        /// when the data is not a usable profile.
        public func register(iccData data: Data) -> ProfileRef? {
            guard var ref = ProfileRegistry.makeRef(iccData: data) else {
                return nil
            }
            return lock.withLock {
                if let id = bundledByNormalizedHash[ProfileRegistry.normalizedHash(data)], let bundled = bundledByID[id] {
                    ref = bundled
                } else {
                    dataByHash[ref.sha256] = data
                }
                return ref
            }
        }

        /// Registers the profile behind a colour space (a display's `NSScreen.colorSpace`).
        public func register(colorSpace: CGColorSpace) -> ProfileRef? {
            guard let data = colorSpace.copyICCData() as Data? else {
                return nil
            }
            return register(iccData: data)
        }

        // MARK: Resolution

        /// The ICC bytes of `ref`: bundled, registered, or from the blob loader; nil while a
        /// custom profile's blob is not local.
        public func iccData(for ref: ProfileRef) -> Data? {
            let (cached, loader) = lock.withLock { (dataByHash[ref.sha256], self.loader) }
            if let cached {
                return cached
            }
            guard let data = loader?(ref.sha256), ProfileRegistry.hash(data) == ref.sha256 else {
                return nil
            }
            lock.withLock { dataByHash[ref.sha256] = data }
            return data
        }

        /// The colour space of `ref`, cached by hash; nil while its data is not available.
        public func colorSpace(for ref: ProfileRef) -> CGColorSpace? {
            if let cached = lock.withLock({ spaceByHash[ref.sha256] }) {
                return cached
            }
            guard let data = iccData(for: ref), let space = CGColorSpace(iccData: data as CFData) else {
                return nil
            }
            lock.withLock { spaceByHash[ref.sha256] = space }
            return space
        }

        /// What `ref` renders through: itself when its data is available, otherwise the
        /// bundled default of its space with `pending` set; an unset ref reads as `fallback`.
        public func resolve(_ ref: ProfileRef?, default fallback: ProfileRef) -> (profile: ProfileRef, colorSpace: CGColorSpace, pending: Bool) {
            if let ref, let space = colorSpace(for: ref) {
                return (ref, space, false)
            }
            let substitute = ref.map { self.fallback(for: $0.space) } ?? fallback
            return (substitute, colorSpace(for: substitute)!, ref != nil)
        }

        // MARK: Installed profiles

        /// The profiles installed on this Mac (system, local and user ColorSync folders),
        /// excluding device links, abstract and named-colour profiles, optionally filtered by
        /// space, sorted by name.
        public func installedProfiles(space: ProfileSpace? = nil) -> [InstalledProfile] {
            final class Collector {
                var found: [InstalledProfile] = []
            }
            let collector = Collector()
            let context = Unmanaged.passUnretained(collector).toOpaque()
            ColorSyncIterateInstalledProfiles({ info, userInfo in
                let collector = Unmanaged<Collector>.fromOpaque(userInfo!).takeUnretainedValue()
                if let profile = ProfileRegistry.installedProfile(from: info as NSDictionary?) {
                    collector.found.append(profile)
                }
                return true
            }, nil, context, nil)
            return collector.found
                .filter { space == nil || $0.space == space }
                .sorted { ($0.name, $0.url.path) < ($1.name, $1.url.path) }
        }

        /// The profile described by one `ColorSyncIterateInstalledProfiles` dictionary, or nil
        /// for a class or space the menus never offer.
        static func installedProfile(from info: NSDictionary?) -> InstalledProfile? {
            guard let info,
                  let profileClass = info[kColorSyncProfileClass.takeUnretainedValue()] as? String,
                  ["mntr", "prtr", "scnr", "spac"].contains(profileClass),
                  let signature = info[kColorSyncProfileColorSpace.takeUnretainedValue()] as? String,
                  let space = ProfileSpace(signature: signature),
                  let url = info[kColorSyncProfileURL.takeUnretainedValue()] as? URL
            else {
                return nil
            }
            let name = info[kColorSyncProfileDescription.takeUnretainedValue()] as? String ?? url.deletingPathExtension().lastPathComponent
            return InstalledProfile(name: name, url: url, space: space, profileClass: profileClass)
        }
    }
}
