import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto

/// Presents the typeface sheets: on the front window, or as a window of its own when none is open
/// (menu:File[New Typeface…] with no document).
@MainActor
enum TypefaceSheets {
    /// The sheet, for its close button.  Weak over a parent (the parent holds its attached sheet;
    /// a strong reference here made a cycle through the sheet's own close button, so every sheet
    /// -- and whatever its model held, the document window included -- stayed after closing);
    /// strong for a window of its own until it closes.
    private final class Holder {
        weak var window: NSWindow?
        var own: NSWindow?
    }

    static func present<Content: View>(_ identifier: String, on parent: NSWindow?, @ViewBuilder content: (@escaping @MainActor () -> Void) -> Content) -> NSWindow {
        let holder = Holder()
        let close: @MainActor () -> Void = { [weak parent] in
            guard let sheet = holder.window else { return }
            if let parent, parent.attachedSheet === sheet { parent.endSheet(sheet) } else { sheet.close() }
            holder.own = nil
        }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: content(close)))
        sheet.identifier = NSUserInterfaceItemIdentifier(identifier)
        sheet.isReleasedWhenClosed = false
        holder.window = sheet
        if let parent {
            parent.beginSheet(sheet)
        } else {
            holder.own = sheet
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
        }
        return sheet
    }
}

// MARK: New Typeface

/// The New Typeface sheet (typeface-documents.adoc, "Creating a typeface document"; FONT-003):
/// family and style names, the starting set and the units per em.
@MainActor
@Observable
final class NewTypefaceModel {
    enum StartingSet: String, CaseIterable, Identifiable {
        case empty, basicLatin, latin1, fromFile

        var id: String { rawValue }

        var title: String {
            switch self {
            case .empty: "Empty"
            case .basicLatin: "Basic Latin"
            case .latin1: "Latin-1"
            case .fromFile: "From a font file…"
            }
        }

        var glyphSet: GlyphSet? {
            switch self {
            case .basicLatin: .basicLatin
            case .latin1: .latin1
            case .empty, .fromFile: nil
            }
        }
    }

    struct Choice: Hashable {
        var family: String
        var style: String
        var set: StartingSet
        var upm: Int
    }

    var family = ""
    var style = "Regular"
    var set: StartingSet = .basicLatin
    var upmText = String(WTModel.FontInfo.defaultUPM)
    private(set) var problem: String?
    @ObservationIgnored let create: @MainActor (Choice) -> Void

    init(create: @escaping @MainActor (Choice) -> Void) {
        self.create = create
    }

    static let invalidUPM = "Units per em must be a whole number from 16 to 16384"

    /// btn:[Create].
    @discardableResult
    func commit() -> Bool {
        guard let upm = Int(upmText.trimmingCharacters(in: .whitespaces)), WTModel.FontInfo.upmRange.contains(upm) else {
            problem = Self.invalidUPM
            return false
        }
        create(Choice(family: family.trimmingCharacters(in: .whitespaces), style: style.trimmingCharacters(in: .whitespaces), set: set, upm: upm))
        return true
    }
}

struct NewTypefaceSheet: View {
    @Bindable var model: NewTypefaceModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Typeface").font(.headline)
            Form {
                TextField("Family name", text: $model.family).accessibilityIdentifier("newTypeface.family")
                TextField("Style name", text: $model.style).accessibilityIdentifier("newTypeface.style")
                Picker("Starting set", selection: $model.set) {
                    ForEach(NewTypefaceModel.StartingSet.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("newTypeface.set")
                TextField("Units per em", text: $model.upmText).accessibilityIdentifier("newTypeface.upm")
            }
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Create", action: SheetButtons.closing(model.commit, close)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("newTypeface.create")
            }
        }
        .padding()
        .frame(width: 360)
    }
}

// MARK: Add Glyph

/// The Add Glyph sheet (glyph-grid.adoc, "Adding glyphs"; FONT-010): characters (`é`, `ÀÁÂ`), a
/// codepoint or range (`U+00E9`, `U+00C0-U+00FF`) or a glyph name (`eacute`, `f_i`, `a.alt`),
/// added after the selected glyph in one change; glyphs that exist are skipped.  *Kind* follows
/// what the text names (Mark for a combining character, Ligature for `f_i`, else Base) until it is
/// chosen; a Component is unencoded.  btn:[Add and Open] opens the (first) glyph added as well.
/// The Basic Latin and Latin-1 buttons add a starting set's missing glyphs.
@MainActor
@Observable
final class AddGlyphModel {
    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let after: OpID?
    @ObservationIgnored let perform: TypefacePerform
    var text = "" {
        didSet { if !kindChosen { kind = Self.glyphs(for: text)?.first?.kind ?? .base } }
    }
    /// The kind the glyphs get.
    private(set) var kind: GlyphKind = .base
    @ObservationIgnored private var kindChosen = false
    private(set) var problem: String?
    /// Opens a glyph in a tab (btn:[Add and Open]).
    @ObservationIgnored var openGlyph: @MainActor (OpID) -> Void = { _ in }

    init(document: DocumentHandle, after: OpID?, perform: @escaping TypefacePerform) {
        self.document = document
        self.after = after
        self.perform = perform
    }

    static let nothing = "Type characters, a codepoint such as U+00E9, or a glyph name"
    static let exists = "Every glyph named is already in the font"

    /// The *Kind* pop-up chose `kind`.
    func choose(_ kind: GlyphKind) {
        kindChosen = true
        self.kind = kind
    }

    /// The glyphs `text` asks for, nil when it names none.
    static func glyphs(for text: String) -> [NewGlyph]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.uppercased().hasPrefix("U+") {
            let bounds = trimmed.split(whereSeparator: { $0 == "-" || $0 == "–" }).map { part -> UInt32? in
                var hex = part.trimmingCharacters(in: .whitespaces).uppercased()
                if hex.hasPrefix("U+") { hex.removeFirst(2) }
                return UInt32(hex, radix: 16)
            }
            let values = bounds.compactMap { $0 }
            guard values.count == bounds.count, (1...2).contains(values.count) else { return nil }
            let low = values[0], high = values[values.count - 1]
            guard low <= high, high <= 0x10FFFF, high - low < 0x1000 else { return nil }
            return (low...high).filter { !(0xD800...0xDFFF).contains($0) }.map(NewGlyph.init(scalar:))
        }
        if trimmed.unicodeScalars.count > 1, GlyphNaming.isValid(trimmed) {
            return [NewGlyph(named: trimmed)]
        }
        return trimmed.unicodeScalars.filter { !$0.properties.isWhitespace }.map { NewGlyph(scalar: $0.value) }
    }

    /// The glyphs btn:[Add] adds: those missing, with the kind (a Component without codepoints).
    func missing() -> [NewGlyph]? {
        guard let glyphs = Self.glyphs(for: text), !glyphs.isEmpty else {
            problem = Self.nothing
            return nil
        }
        let index = GlyphIndex(document.state)
        let missing = glyphs.filter { glyph in
            !index.isNameTaken(glyph.name) && !glyph.codepoints.contains { index.holder(of: $0) != nil }
        }
        guard !missing.isEmpty else {
            problem = Self.exists
            return nil
        }
        // Each glyph keeps the kind its text implies until one is chosen.
        guard kindChosen else { return missing }
        let kind = kind
        return missing.map { glyph in
            var copy = glyph
            copy.kind = kind
            if kind == .component { copy.codepoints = [] }
            return copy
        }
    }

    /// btn:[Add].
    @discardableResult
    func commit() -> Bool {
        guard let glyphs = missing() else { return false }
        _ = perform(AddGlyphs(glyphs, after: after, skipExisting: true))
        return true
    }

    /// btn:[Add and Open]: adds, then opens the first glyph added once the change is in.
    @discardableResult
    func addAndOpen() -> Task<OpID?, Never>? {
        guard let glyphs = missing(), let name = glyphs.first?.name else { return nil }
        let change = perform(AddGlyphs(glyphs, after: after, skipExisting: true))
        let document = document
        return Task { [weak self] in
            _ = await change?.value
            guard let glyph = GlyphIndex(document.state).glyph(named: name)?.id else { return nil }
            self?.openGlyph(glyph)
            return glyph
        }
    }

    func addAndOpenButton() -> Bool { addAndOpen() != nil }

    /// btn:[Add Basic Latin] / btn:[Add Latin-1].
    @discardableResult
    func add(_ set: GlyphSet) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        perform(set.command(after: after))
    }

    func addBasicLatin() -> Bool { add(.basicLatin) != nil }
    func addLatin1() -> Bool { add(.latin1) != nil }
}

struct AddGlyphSheet: View {
    @Bindable var model: AddGlyphModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Glyph").font(.headline)
            TextField("Characters, U+0041 or a glyph name", text: $model.text).accessibilityIdentifier("addGlyph.text")
            Picker("Kind", selection: Binding(get: { model.kind }, set: { kind in model.choose(kind) })) {
                ForEach(GlyphKind.allCases, id: \.self) { kind in Text(TypefaceFeatures.title(of: kind)).tag(kind) }
            }
            .fixedSize()
            .accessibilityIdentifier("addGlyph.kind")
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Add Basic Latin", action: SheetButtons.closing(model.addBasicLatin, close))
                Button("Add Latin-1", action: SheetButtons.closing(model.addLatin1, close))
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Add and Open", action: SheetButtons.closing(model.addAndOpenButton, close)).accessibilityIdentifier("addGlyph.addAndOpen")
                Button("Add", action: SheetButtons.closing(model.commit, close)).keyboardShortcut(.defaultAction).accessibilityIdentifier("addGlyph.add")
            }
        }
        .padding()
        .frame(width: 520)
    }
}

// MARK: Convert Document To

/// menu:File[Convert Document To] (typeface-documents.adoc, "Converting a document to another
/// kind"): what the conversion does, its option, and btn:[Convert] -- one change.
@MainActor
@Observable
final class ConvertDocumentModel {
    @ObservationIgnored let document: DocumentHandle
    let kind: DocumentKind
    @ObservationIgnored let perform: TypefacePerform
    var addBasicLatin = false
    var copyGlyphsToPages = false
    private(set) var problem: String?

    init(document: DocumentHandle, kind: DocumentKind, perform: @escaping TypefacePerform) {
        self.document = document
        self.kind = kind
        self.perform = perform
    }

    var current: DocumentKind { DocumentKind(document.state) }

    /// What the sheet says will happen.
    var explanation: String {
        switch (current, kind) {
        case (let from, let to) where from == to:
            "The document is already a \(to.title.lowercased())."
        case (_, .singlePage):
            "The page controls are hidden.  A document converts to single-page only when it has exactly one page."
        case (_, .multiPage) where current != .typeface:
            "Pages can be added again."
        case (_, .typeface):
            "The pages become the Sketches view and the glyph grid opens.  Font settings start from their defaults (a 1000-unit em)."
        default:
            "The glyphs are kept, hidden, so converting back restores them."
        }
    }

    var hasOption: Bool { kind != current && (kind == .typeface || current == .typeface) }

    /// btn:[Convert].
    @discardableResult
    func commit() -> Bool {
        guard kind != current else { return true }
        let pages = PageList(document.state).pages.filter { !$0.isSynthesized }.count
        if kind == .singlePage, pages > 1 {
            problem = "The document has \(pages) pages.  Remove all but one in the Document panel first."
            return false
        }
        let options = ConvertDocumentKind.Options(addBasicLatin: kind == .typeface && addBasicLatin,
                                                  copyGlyphsToPages: current == .typeface && copyGlyphsToPages)
        _ = perform(ConvertDocumentKind(to: kind, options: options))
        return true
    }
}

struct ConvertDocumentSheet: View {
    @Bindable var model: ConvertDocumentModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Convert to \(model.kind.title)").font(.headline)
            Text(model.explanation).fixedSize(horizontal: false, vertical: true)
            if model.hasOption {
                if model.kind == .typeface {
                    Toggle("Add the Basic Latin glyph set", isOn: $model.addBasicLatin).accessibilityIdentifier("convert.basicLatin")
                } else {
                    Toggle("Copy every glyph to its own page", isOn: $model.copyGlyphsToPages).accessibilityIdentifier("convert.copyGlyphs")
                }
            }
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Convert", action: SheetButtons.closing(model.commit, close)).keyboardShortcut(.defaultAction).accessibilityIdentifier("convert.ok")
            }
        }
        .padding()
        .frame(width: 380)
    }
}

// MARK: Convert Page to Glyph

/// menu:Glyph[Convert Page to Glyph…] (typeface-documents.adoc, "Bringing artwork into a
/// glyph"): the glyph's name or character, the scaling and Move or Copy.
@MainActor
@Observable
final class ConvertPageModel {
    @ObservationIgnored let document: DocumentHandle
    let page: OpID
    @ObservationIgnored let perform: @MainActor (ConvertPageToGlyph) -> Void
    var text = ""
    var pageHeightIsEm = true
    var move = true
    private(set) var problem: String?

    init(document: DocumentHandle, page: OpID, perform: @escaping @MainActor (ConvertPageToGlyph) -> Void) {
        self.document = document
        self.page = page
        self.perform = perform
    }

    static let invalid = "Type a single character or a glyph name"

    /// The command the sheet describes, nil when the text names no glyph (a message says why).
    func command() -> ConvertPageToGlyph? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let name: String
        var codepoints: [UInt32]?
        if trimmed.unicodeScalars.count == 1, let scalar = trimmed.unicodeScalars.first {
            name = GlyphNaming.name(for: scalar.value)
            codepoints = [scalar.value]
        } else if GlyphNaming.isValid(trimmed) {
            name = trimmed
        } else {
            problem = Self.invalid
            return nil
        }
        if GlyphIndex(document.state).isNameTaken(name) {
            problem = "A glyph named “\(name)” exists"
            return nil
        }
        return ConvertPageToGlyph(page, name: name, codepoints: codepoints, scaling: pageHeightIsEm ? .pageHeightIsEm : .onePointPerUnit, move: move)
    }

    /// btn:[Convert].
    @discardableResult
    func commit() -> Bool {
        guard let command = command() else { return false }
        perform(command)
        return true
    }
}

struct ConvertPageSheet: View {
    @Bindable var model: ConvertPageModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Convert Page to Glyph").font(.headline)
            TextField("Glyph name or character", text: $model.text).accessibilityIdentifier("convertPage.name")
            Picker("Scale", selection: $model.pageHeightIsEm) {
                Text("Page height is the em").tag(true)
                Text("One point per unit").tag(false)
            }
            Picker("Objects", selection: $model.move) {
                Text("Move").tag(true)
                Text("Copy").tag(false)
            }
            .pickerStyle(.segmented)
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Convert", action: SheetButtons.closing(model.commit, close)).keyboardShortcut(.defaultAction).accessibilityIdentifier("convertPage.ok")
            }
        }
        .padding()
        .frame(width: 360)
    }
}
