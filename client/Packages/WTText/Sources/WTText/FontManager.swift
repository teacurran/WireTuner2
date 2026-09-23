// Font management (TXT-002; docs/_includes/document/font-substitution.adoc, "Client";
// print-fonts.adoc).  A face the document names is looked up through installed → embedded →
// team library → substitution table → default substitute, and the step that answered is
// reported so the Missing Fonts sheet, the Text panel's badge and the print check can show it.
//
// Embedded and team-library fonts are *activated*: their files are registered with Core Text
// for this process only, so every layer that names a face by family or PostScript name --
// WTText's resolver, WTRender's glyph runs, PDF output -- finds them, and nothing is installed
// on the Mac.  Registration is process-wide, so activations are shared by every `FontManager`;
// the substitution tables are per manager (one per document, or `shared`).  Whatever changes
// the answer bumps `generation`.  A manager's own changes (its tables, the catalog, a refresh)
// drop everything its resolver cached; an activation drops only what it can change -- fonts
// laid out in the families it registered or unregistered, and faces that now resolve
// differently -- so one document activating its embedded fonts leaves every other document's
// cached fonts in place.

import CoreText
import CryptoKit
import Foundation
import WTRender

/// Which step of the lookup chain supplied a face.
public enum FontSource: String, Hashable, Sendable, CaseIterable {
    /// Installed on this Mac (Font Book included).
    case installed
    /// A font file embedded in the document, activated for this process.
    case embedded
    /// A font fetched from the team's font library, activated for this process.
    case teamLibrary
    /// A row of the substitution table (the document's, then the remembered ones).
    case substitution
    /// No row: the table's default substitute.
    case defaultSubstitute

    /// Whether the face laid out is a stand-in for the one named.
    public var isSubstitute: Bool {
        self == .substitution || self == .defaultSubstitute
    }
}

/// Where an activated font came from.
public enum ActivationSource: String, Hashable, Sendable, CaseIterable {
    case embedded
    case teamLibrary

    var fontSource: FontSource {
        self == .embedded ? .embedded : .teamLibrary
    }
}

/// One substitution: the missing face (a nil style covers every style of the family) and its
/// stand-in (a nil style keeps the run's own style).
public struct FontSubstitution: Hashable, Sendable {
    public var missing: FaceName
    public var substitute: FaceName

    public init(missing: FaceName, substitute: FaceName) {
        self.missing = missing
        self.substitute = substitute
    }
}

/// The *Font substitutions* table: rows and the *Default substitute* row
/// (`Preferences.font_substitutions`).
public struct FontSubstitutionTable: Hashable, Sendable {
    /// The substitute when no row matches (font-substitution.adoc).
    public static let standardDefault = FaceName(family: "Helvetica Neue")

    public var rows: [FontSubstitution]
    public var defaultSubstitute: FaceName

    public init(rows: [FontSubstitution] = [], defaultSubstitute: FaceName = FontSubstitutionTable.standardDefault) {
        self.rows = rows
        self.defaultSubstitute = defaultSubstitute
    }

    /// The row for `face`: one naming its style (ignoring case) before one covering the family.
    public func row(for face: FaceName) -> FontSubstitution? {
        FontSubstitutionTable.row(for: face, in: rows)
    }

    static func row(for face: FaceName, in rows: [FontSubstitution]) -> FontSubstitution? {
        let style = face.style?.lowercased()
        return rows.first { $0.missing.family == face.family && $0.missing.style != nil && $0.missing.style?.lowercased() == style }
            ?? rows.first { $0.missing.family == face.family && $0.missing.style == nil }
    }
}

/// How a named face was answered: the step and the face laid out in its place.
public struct FontResolution: Hashable, Sendable {
    public var source: FontSource
    public var face: FaceName

    public init(source: FontSource, face: FaceName) {
        self.source = source
        self.face = face
    }
}

/// A font's embedding licence: its OpenType `OS/2.fsType` (0 when the font has no OS/2 table).
public struct FontEmbedding: Hashable, Sendable {
    public let fsType: UInt16

    public init(fsType: UInt16) {
        self.fsType = fsType
    }

    /// The font's permission, read from its OS/2 table.
    public init(_ font: CTFont) {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 10 else {
            self.init(fsType: 0)
            return
        }
        self.init(fsType: UInt16(table[table.startIndex + 8]) << 8 | UInt16(table[table.startIndex + 9]))
    }

    private var usage: UInt16 { fsType & 0x000F }

    /// Installable embedding: no usage bit set.
    public var isInstallable: Bool { usage == 0 }
    /// Editable embedding (bit 3).
    public var allowsEditing: Bool { isInstallable || fsType & 0x0008 != 0 }
    /// Preview & Print embedding (bit 2), or anything less restrictive.
    public var allowsPreviewAndPrint: Bool { allowsEditing || fsType & 0x0004 != 0 }
    /// Restricted licence embedding: bit 1 with no less restrictive bit (the least restrictive
    /// bit set applies).
    public var isRestricted: Bool { !allowsPreviewAndPrint && fsType & 0x0002 != 0 }
    /// Bitmap embedding only (bit 9): no outlines may be embedded.
    public var isBitmapOnly: Bool { fsType & 0x0200 != 0 }
    /// No subsetting (bit 8).
    public var forbidsSubsetting: Bool { fsType & 0x0100 != 0 }

    /// Whether the font file may be embedded in a document others open and edit: installable
    /// or editable, with outlines.
    public var allowsDocumentEmbedding: Bool { allowsEditing && !isBitmapOnly }
    /// Whether it may be embedded in a PDF or print job (print-fonts.adoc).
    public var allowsPrintEmbedding: Bool { allowsPreviewAndPrint && !isBitmapOnly }
}

public enum FontActivationError: Error, Hashable, Sendable {
    /// The file holds no font Core Text can read.
    case unreadable
    /// A document-embedded font whose licence forbids embedding (restricted, or bitmap only).
    case notLicensedForEmbedding(FaceName)
    /// Core Text refused the registration (its `CTFontManagerError` code).
    case registrationFailed(Int)
}

/// The fonts this process has activated, shared by every manager.
final class FontActivations: @unchecked Sendable {
    static let shared = FontActivations()

    struct Entry {
        let source: ActivationSource
        let faces: [FaceName]
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]
    private var counter = 0
    /// The `counter` at which each family's activations last changed.
    private var changes: [String: Int] = [:]
    /// Registers a font file for the process; the `CTFontManagerError` code when Core Text
    /// refuses it (replaced in tests).
    let register: @Sendable (URL) -> Int?

    init(register: @escaping @Sendable (URL) -> Int? = FontActivations.registerWithCoreText) {
        self.register = register
    }

    static func registerWithCoreText(_ url: URL) -> Int? {
        var error: Unmanaged<CFError>?
        guard !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
            return nil
        }
        return error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
    }

    var generation: Int { lock.withLock { counter } }

    /// Whether any of `families` was activated or deactivated after `generation`.
    func changed(_ families: some Sequence<String>, since generation: Int) -> Bool {
        lock.withLock { families.contains { changes[$0, default: 0] > generation } }
    }

    /// The source of the first activation that supplies `family`: embedded before team library.
    func source(of family: String) -> FontSource? {
        lock.withLock {
            let sources = entries.values.filter { $0.faces.contains { $0.family == family } }.map(\.source)
            return sources.contains(.embedded) ? .embedded : sources.first?.fontSource
        }
    }

    var families: Set<String> {
        lock.withLock { Set(entries.values.flatMap { $0.faces.map(\.family) }) }
    }

    func faces(from source: ActivationSource) -> [FaceName] {
        lock.withLock { entries.values.filter { $0.source == source }.flatMap(\.faces) }
    }

    func urls(from source: ActivationSource) -> [URL] {
        lock.withLock { entries.filter { $0.value.source == source }.map(\.key) }
    }

    /// Registers the fonts in `url` for the process.  Faces an installed font already provides
    /// are not activated (installed wins); the result is the faces that were.
    func activate(_ url: URL, source: ActivationSource, installed: (String) -> Bool) throws -> [FaceName] {
        let url = url.standardizedFileURL
        if let known = lock.withLock({ entries[url] }) {
            return known.faces
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty else {
            throw FontActivationError.unreadable
        }
        let faces = descriptors.map { descriptor -> FaceName in
            FaceName(
                family: CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String ?? "",
                style: CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String
            )
        }
        if source == .embedded {
            for (descriptor, face) in zip(descriptors, faces) {
                let embedding = FontEmbedding(CTFontCreateWithFontDescriptor(descriptor, 12, nil))
                if !embedding.allowsPrintEmbedding {
                    throw FontActivationError.notLicensedForEmbedding(face)
                }
            }
        }
        let fresh = faces.filter { !installed($0.family) }
        guard !fresh.isEmpty else {
            return []
        }
        // The same file registered by someone else in this process is as good as ours.
        if let code = register(url), code != CTFontManagerError.alreadyRegistered.rawValue {
            throw FontActivationError.registrationFailed(code)
        }
        lock.withLock {
            entries[url] = Entry(source: source, faces: fresh)
            counter += 1
            for face in fresh {
                changes[face.family] = counter
            }
        }
        GlyphFont.fontsChanged()
        return fresh
    }

    /// Unregisters `url`; false when it was not activated here.
    @discardableResult
    func deactivate(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        guard let entry = lock.withLock({ entries.removeValue(forKey: url) }) else {
            return false
        }
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
        lock.withLock {
            counter += 1
            for face in entry.faces {
                changes[face.family] = counter
            }
        }
        GlyphFont.fontsChanged()
        return true
    }
}

/// The font environment layout resolves against: installed fonts, the process's activated
/// fonts, the team library's catalog and the substitution tables.
public final class FontManager: @unchecked Sendable {
    /// The manager `TextLayoutEngine()` and WTText's shared resolver use.
    public static let shared = FontManager()

    /// The family laid out when the default substitute is not installed either.
    static let lastResortFamily = "Helvetica"

    private let lock = NSLock()
    private var table: FontSubstitutionTable
    private var documentRows: [FontSubstitution] = []
    private var catalog: Set<String> = []
    private var counter = 0
    private var systemFamilies: (generation: Int, answers: [String: Bool])?
    /// Run fonts for this manager's layouts; set once in `init`.
    private(set) var resolver: FontResolver!

    public init(substitutions: FontSubstitutionTable = FontSubstitutionTable()) {
        table = substitutions
        resolver = FontResolver(manager: self)
    }

    /// The remembered substitutions and the default substitute (a preference).
    public var substitutions: FontSubstitutionTable {
        get { lock.withLock { table } }
        set { lock.withLock { table = newValue; counter += 1 } }
    }

    /// Substitutions for this document only (the sheet without *Remember this substitution*,
    /// and the per-Mac record of them); they come before the remembered rows.
    public var documentSubstitutions: [FontSubstitution] {
        get { lock.withLock { documentRows } }
        set { lock.withLock { documentRows = newValue; counter += 1 } }
    }

    /// The families the team's font library offers (from its catalog), whether or not they have
    /// been fetched: a missing family listed here is reported as waiting for the library.
    public var teamLibraryFamilies: Set<String> {
        get { lock.withLock { catalog } }
        set { lock.withLock { catalog = newValue; counter += 1 } }
    }

    /// Changes whenever a lookup could answer differently: a table, the catalog, an activation
    /// or `refreshInstalledFonts()`.
    public var generation: Int {
        epoch.sum
    }

    /// Where `generation` stands: this manager's own changes and the process's activations.
    struct Epoch: Hashable {
        let manager: Int
        let activations: Int

        var sum: Int { manager + activations }
    }

    var epoch: Epoch {
        Epoch(manager: lock.withLock { counter }, activations: FontActivations.shared.generation)
    }

    /// Whether what `report` recorded, resolved at `epoch`, still holds: every named face
    /// resolves as it did, and no family laid out in its place was activated or deactivated
    /// since (a face added to an activated family changes the font laid out without changing
    /// the resolution).
    func stillHolds(_ report: FontReport, since epoch: Epoch) -> Bool {
        report.resolutions.allSatisfy { resolve($0.key) == $0.value }
            && !FontActivations.shared.changed(report.resolutions.values.map(\.face.family), since: epoch.activations)
    }

    /// Re-reads the installed families (after Font Book activated or removed fonts).
    public func refreshInstalledFonts() {
        lock.withLock {
            systemFamilies = nil
            counter += 1
        }
    }

    // MARK: Lookup

    /// Whether `family` is installed on this Mac (not merely activated here).
    public func isInstalled(_ family: String) -> Bool {
        loads(family) && FontActivations.shared.source(of: family) == nil
    }

    /// Whether `family` can be laid out as itself: installed or activated.
    public func isAvailable(_ family: String) -> Bool {
        loads(family) || FontActivations.shared.source(of: family) != nil
    }

    /// Every family that can be laid out, sorted: the substitute pickers' list.
    public func families() -> [String] {
        Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).union(FontActivations.shared.families).sorted()
    }

    /// The style names of `family`'s faces, sorted; empty for a family that is not available.
    public func styles(of family: String) -> [String] {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let faces = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, Set([kCTFontFamilyNameAttribute as String]) as CFSet) as? [CTFontDescriptor] ?? []
        return Set(faces.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontStyleNameAttribute) as? String }).sorted()
    }

    /// How `face` resolves: installed → embedded → team library → the document's then the
    /// remembered substitution rows (whose substitute is available) → the default substitute.
    public func resolve(_ face: FaceName) -> FontResolution {
        if isInstalled(face.family) {
            return FontResolution(source: .installed, face: face)
        }
        if let source = FontActivations.shared.source(of: face.family) {
            return FontResolution(source: source, face: face)
        }
        let (table, rows) = lock.withLock { (self.table, documentRows) }
        for candidates in [rows, table.rows] {
            if let row = FontSubstitutionTable.row(for: face, in: candidates.filter({ isAvailable($0.substitute.family) })) {
                return FontResolution(source: .substitution, face: FaceName(family: row.substitute.family, style: row.substitute.style ?? face.style))
            }
        }
        let fallback = isAvailable(table.defaultSubstitute.family) ? table.defaultSubstitute : FaceName(family: FontManager.lastResortFamily)
        return FontResolution(source: .defaultSubstitute, face: FaceName(family: fallback.family, style: fallback.style ?? face.style))
    }

    /// The report for `faces` without laying anything out: what the Missing Fonts sheet reads
    /// before a document's first render, and the print check over a job's faces.
    public func report(for faces: Set<FaceName>) -> FontReport {
        var report = FontReport()
        for face in faces {
            report.record(face, resolve(face), teamLibrary: teamLibraryFamilies)
        }
        return report
    }

    /// The installed or activated face `face` names, if there is one.
    public func font(for face: FaceName, size: Double = 12) -> CTFont? {
        guard isAvailable(face.family) else {
            return nil
        }
        if let style = face.style {
            return FontResolver.face(family: face.family, style: style, size: size)
        }
        return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: face.family] as CFDictionary), CGFloat(size), nil)
    }

    /// The embedding licence of an available face (for *where licensed*: WTApp embeds a font
    /// in the document only when `allowsDocumentEmbedding`).
    public func embedding(of face: FaceName) -> FontEmbedding? {
        font(for: face).map(FontEmbedding.init)
    }

    /// The file an available face is loaded from: what WTApp uploads as the embedded blob.
    public func fileURL(of face: FaceName) -> URL? {
        font(for: face).flatMap { CTFontCopyAttribute($0, kCTFontURLAttribute) as? URL }
    }

    // MARK: Activation

    /// Activates the fonts in the file at `url` (an embedded or team-library font blob in the
    /// local cache) for this process.  Returns the faces now available; faces an installed
    /// font already provides are skipped.  An embedded font whose licence forbids embedding is
    /// refused.
    @discardableResult
    public func activate(fontsAt url: URL, source: ActivationSource) throws -> [FaceName] {
        try FontActivations.shared.activate(url, source: source) { self.isInstalled($0) }
    }

    /// Activates font file bytes, written once (by content) under `directory`.
    @discardableResult
    public func activate(_ data: Data, source: ActivationSource, directory: URL = FontManager.activationDirectory) throws -> [FaceName] {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("\(digest).\(FontManager.fileExtension(of: data))")
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return try activate(fontsAt: url, source: source)
    }

    /// Unregisters the fonts activated from `url`.
    @discardableResult
    public func deactivate(fontsAt url: URL) -> Bool {
        FontActivations.shared.deactivate(url)
    }

    /// Unregisters every activation from `source` (a closed document's embedded fonts).
    public func deactivateAll(from source: ActivationSource) {
        for url in FontActivations.shared.urls(from: source) {
            FontActivations.shared.deactivate(url)
        }
    }

    /// The faces activated from `source`.
    public func activatedFaces(from source: ActivationSource) -> [FaceName] {
        FontActivations.shared.faces(from: source)
    }

    /// Where `activate(_:source:)` writes font bytes by default.
    public static let activationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("WTTextFonts", isDirectory: true)

    /// The file extension for font bytes: OpenType CFF, a collection, or TrueType.
    static func fileExtension(of data: Data) -> String {
        switch data.prefix(4) {
        case Data("OTTO".utf8): return "otf"
        case Data("ttcf".utf8): return "ttc"
        default: return "ttf"
        }
    }

    // MARK: Internals

    /// Whether Core Text loads a face of `family` (installed or registered), cached per family
    /// until fonts are activated or refreshed.  Matched by descriptor rather than read from
    /// `CTFontManagerCopyAvailableFontFamilyNames`, which leaves out system families such as
    /// Courier and Times.
    private func loads(_ family: String) -> Bool {
        let generation = FontActivations.shared.generation
        if let cached = lock.withLock({ systemFamilies?.generation == generation ? systemFamilies?.answers[family] : nil }) {
            return cached
        }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let found = !(CTFontDescriptorCreateMatchingFontDescriptors(descriptor, Set([kCTFontFamilyNameAttribute as String]) as CFSet) as? [CTFontDescriptor] ?? []).isEmpty
        lock.withLock {
            if systemFamilies?.generation != generation {
                systemFamilies = (generation, [:])
            }
            systemFamilies?.answers[family] = found
        }
        return found
    }
}
