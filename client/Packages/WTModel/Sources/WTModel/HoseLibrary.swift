import Dispatch
import Foundation
import WTCRDT
import WTGeometry
import WTProto

// DRAW-038: library hoses (docs/_includes/drawing/graphic-hose.adoc, "Where hoses live", "Client:
// Library").  A library hose is a `.wthose` directory bundle: `hose.binpb`, the `hose_set` subtree
// in the native pasteboard encoding (`ClipboardPayload` with the set as its one node: the same
// doc.v1 messages, plus each object's attribute-stack order, so a round trip is lossless), and an
// optional `preview.png` the app renders.  `HoseLibrary` keeps them in
// ~/Library/Application Support/WireTuner/Graphic Hoses.

/// A `.wthose` bundle's contents.
public struct HoseBundle: Hashable, Sendable {
    public static let pathExtension = "wthose"
    static let contentsFile = "hose.binpb"
    static let previewFile = "preview.png"

    /// The `hose_set` node with its objects.
    public var tree: NodeTree

    /// A bundle of `tree`, which must be a `hose_set`.
    public init(tree: NodeTree) throws(HoseError) {
        guard case .hoseSet? = tree.props.kind else { throw .unreadableBundle }
        self.tree = tree
    }

    /// The document set `set` for the library: its tree, with the library identity `libraryID`
    /// in its note (a fresh one when nil).
    public init(set: OpID, in state: EngineState, libraryID: UUID = UUID()) throws(HoseError) {
        guard HoseSets.set(set, in: state) != nil else { throw .notASet(set) }
        var tree = HoseSets.tree(set, in: state)
        tree.props.hoseSet.common.note = HoseSets.note(libraryID)
        try self.init(tree: tree)
    }

    /// The bundle `bytes` encode.
    public init(decoding bytes: [UInt8]) throws(HoseError) {
        guard let payload = ClipboardPayload(decoding: bytes), payload.nodes.count == 1 else { throw .unreadableBundle }
        try self.init(tree: payload.nodes[0])
    }

    public var name: String { tree.props.hoseSet.common.name }

    /// The library identity, from the set's note.
    public var libraryID: UUID? { HoseSets.libraryID(tree.props.hoseSet.common.note) }

    /// The contents' encoding.
    public func encoded() -> [UInt8] {
        ClipboardPayload(nodes: [tree]).encoded()
    }

    /// Reads the bundle at `url`.
    public static func read(from url: URL) throws -> HoseBundle {
        let data = try Data(contentsOf: url.appendingPathComponent(contentsFile))
        return try HoseBundle(decoding: [UInt8](data))
    }

    /// Writes the bundle to the directory `url` (replacing its contents), with `preview` as its
    /// preview image.
    public func write(to url: URL, preview: Data? = nil) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(encoded()).write(to: url.appendingPathComponent(Self.contentsFile), options: .atomic)
        let previewURL = url.appendingPathComponent(Self.previewFile)
        if let preview {
            try preview.write(to: previewURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: previewURL.path) {
            try FileManager.default.removeItem(at: previewURL)
        }
    }
}

/// The hoses on this Mac.  Bundles are listed by scanning the directory and read only when asked
/// for; `startWatching` reports changes made by anyone (a dropped file, another window) through a
/// dispatch source on the directory.
public actor HoseLibrary {
    /// One bundle in the library.
    public struct Entry: Hashable, Sendable {
        public let url: URL
        /// The bundle's file name without its extension (the set's name when the library wrote it).
        public var name: String { url.deletingPathExtension().lastPathComponent }
        /// The preview image, when the bundle has one.
        public var previewURL: URL? {
            let url = url.appendingPathComponent(HoseBundle.previewFile)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// ~/Library/Application Support/WireTuner/Graphic Hoses.
    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("WireTuner", isDirectory: true).appendingPathComponent("Graphic Hoses", isDirectory: true)
    }

    public nonisolated let directory: URL
    private var source: DispatchSourceFileSystemObject?

    public init(directory: URL = HoseLibrary.defaultDirectory()) {
        self.directory = directory
    }

    /// The bundles now in `directory`, by name.
    public nonisolated static func scan(_ directory: URL) -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == HoseBundle.pathExtension }
            .map { Entry(url: $0.standardizedFileURL) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// At launch: on the first launch (no library directory yet) creates it and installs the
    /// default hoses; returns the bundles.
    @discardableResult
    public func prepare() throws -> [Entry] {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try restoreDefaults()
        }
        return entries()
    }

    /// The bundles now in the library, by name.
    public func entries() -> [Entry] {
        Self.scan(directory)
    }

    /// The bundle of `entry`.
    public func load(_ entry: Entry) throws -> HoseBundle {
        try HoseBundle.read(from: entry.url)
    }

    /// Saves `bundle` as a new library hose named after its set (`-2`, `-3` ... when the name is
    /// taken), giving it a library identity when it has none; returns its entry.
    @discardableResult
    public func save(_ bundle: HoseBundle, preview: Data? = nil) throws -> Entry {
        var bundle = bundle
        if bundle.libraryID == nil { bundle.tree.props.hoseSet.common.note = HoseSets.note(UUID()) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = freeURL(for: bundle.name)
        try bundle.write(to: url, preview: preview)
        return Entry(url: url.standardizedFileURL)
    }

    /// Replaces the bundle of `entry` (an edit to a library hose); a changed name renames it.
    @discardableResult
    public func replace(_ entry: Entry, with bundle: HoseBundle, preview: Data? = nil) throws -> Entry {
        var url = entry.url
        if Self.fileName(bundle.name) != entry.name {
            let renamed = freeURL(for: bundle.name)
            try FileManager.default.moveItem(at: entry.url, to: renamed)
            url = renamed
        }
        try bundle.write(to: url, preview: preview)
        return Entry(url: url.standardizedFileURL)
    }

    /// menu:Sets[Delete…] on a library hose.
    public func delete(_ entry: Entry) throws {
        try FileManager.default.removeItem(at: entry.url)
    }

    /// A `.wthose` dropped on the sheet: copied into the library (under a free name); returns its
    /// entry.  Throws when it is not a hose.
    @discardableResult
    public func importBundle(at url: URL) throws -> Entry {
        let bundle = try HoseBundle.read(from: url)
        let preview = try? Data(contentsOf: url.appendingPathComponent(HoseBundle.previewFile))
        return try save(bundle, preview: preview)
    }

    /// *Restore default hoses*: writes each shipped hose whose library identity no bundle in the
    /// library has.
    public func restoreDefaults() throws {
        let present = Set(entries().compactMap { try? load($0).libraryID })
        for bundle in HoseDefaults.bundles where !present.contains(bundle.libraryID!) {
            try save(bundle)
        }
    }

    /// Reports the library's bundles to `onChange` whenever the directory changes (created,
    /// removed or renamed bundles), until `stopWatching`.
    public func startWatching(_ onChange: @escaping @Sendable ([Entry]) -> Void) throws {
        stopWatching()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                               queue: DispatchQueue(label: "HoseLibrary.watch"))
        let directory = directory
        source.setEventHandler { onChange(HoseLibrary.scan(directory)) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// Stops reporting changes.
    public func stopWatching() {
        source?.cancel()
        source = nil
    }

    /// The file name (without extension) a set called `name` is saved under: slashes and colons
    /// become hyphens, and an empty name is "Hose".
    static func fileName(_ name: String) -> String {
        name.isEmpty ? "Hose" : name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// `name.wthose` in the library, or `name-2.wthose`, ... when taken.
    private func freeURL(for name: String) -> URL {
        let base = Self.fileName(name)
        var candidate = base
        var number = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).appendingPathExtension(HoseBundle.pathExtension).path) {
            candidate = "\(base)-\(number)"
            number += 1
        }
        return directory.appendingPathComponent(candidate).appendingPathExtension(HoseBundle.pathExtension)
    }
}

/// The hoses {product} ships with, built in code so the packages carry no resources: Dots, Stars
/// and Leaves, each with a fixed library identity so *Restore default hoses* knows them.
public enum HoseDefaults {
    public static let bundles: [HoseBundle] = [dots, stars, leaves]

    static func set(_ name: String, id: String, options: (inout Wiretuner_Doc_V1_HoseOptions) -> Void, objects: [NodeTree]) -> HoseBundle {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.hoseSet.common.name = name
        props.hoseSet.common.note = HoseFields.libraryPrefix + id
        options(&props.hoseSet.options)
        return try! HoseBundle(tree: NodeTree(props: props, children: objects))
    }

    /// An ellipse `width` × `height` centred on the origin, turned by `angle` radians.
    static func ellipse(_ width: Double, _ height: Double, angle: Double = 0, red: Double, green: Double, blue: Double) -> NodeTree {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.ellipse.size.width = width
        props.ellipse.size.height = height
        props.ellipse.appearance.fills = [Appearances.basicFill(red: red, green: green, blue: blue)]
        var tree = NodeTree(props: props)
        tree.transform = AffineTransform.translation(x: -width / 2, y: -height / 2).concatenating(.rotation(radians: angle))
        return tree
    }

    /// A five-pointed star of `radius` centred on the origin.
    static func star(_ radius: Double, red: Double, green: Double, blue: Double) -> NodeTree {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.polygon.sides = 5
        props.polygon.star = true
        props.polygon.radius = radius
        props.polygon.autoInner = true
        props.polygon.rotation = -Double.pi / 2
        props.polygon.appearance.fills = [Appearances.basicFill(red: red, green: green, blue: blue)]
        return NodeTree(props: props)
    }

    static let dots = set("Dots", id: "6F1E2D7A-0C1B-4B35-9D0E-2A6C1F3B8D01", options: {
        $0.spacingAmount = 60
        $0.scale = .random
        $0.scalePercent = 120
    }, objects: [
        ellipse(8, 8, red: 0.93, green: 0.26, blue: 0.21),
        ellipse(8, 8, red: 0.98, green: 0.6, blue: 0.13),
        ellipse(8, 8, red: 0.99, green: 0.84, blue: 0.2),
    ])

    static let stars = set("Stars", id: "6F1E2D7A-0C1B-4B35-9D0E-2A6C1F3B8D02", options: {
        $0.order = .random
        $0.spacing = .random
        $0.spacingAmount = 150
        $0.scale = .random
        $0.scalePercent = 100
        $0.rotation = .random
    }, objects: [
        star(6, red: 1, green: 0.84, blue: 0.2),
        star(4, red: 1, green: 1, blue: 1),
    ])

    static let leaves = set("Leaves", id: "6F1E2D7A-0C1B-4B35-9D0E-2A6C1F3B8D03", options: {
        $0.order = .random
        $0.spacingAmount = 80
        $0.rotation = .random
    }, objects: [
        ellipse(14, 5, red: 0.24, green: 0.55, blue: 0.2),
        ellipse(12, 5, angle: 0.4, red: 0.36, green: 0.66, blue: 0.24),
        ellipse(10, 4, angle: -0.4, red: 0.18, green: 0.45, blue: 0.16),
    ])
}
