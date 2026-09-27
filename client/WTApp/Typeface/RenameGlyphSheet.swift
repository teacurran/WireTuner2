import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// menu:Glyph[Rename Glyph…] (glyph-grid.adoc, "Renaming"; opentype-features.adoc, "Feature text
/// vs. glyph rename"; FONT-022's rename sheet button): the new name, refused when it is not a valid
/// glyph name or is live on another glyph; when the feature file uses the old name the sheet says
/// how often ("Used in the feature file, 3 places") and offers btn:[Rename in Feature File], which
/// renames the glyph and rewrites those places in the same change, beside btn:[Rename Glyph Only].
@MainActor
@Observable
final class RenameGlyphModel {
    @ObservationIgnored let document: DocumentHandle
    let glyph: OpID
    let oldName: String
    var name: String
    private(set) var problem: String?
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>?

    init(document: DocumentHandle, glyph: OpID, perform: @escaping @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>?) {
        self.document = document
        self.glyph = glyph
        self.perform = perform
        oldName = GlyphIndex(document.state)[glyph]?.name ?? ""
        name = oldName
    }

    /// How many places the feature file writes the old name.
    var featureUses: Int { RenameInFeatureFile.count(of: oldName, in: document.state) }

    /// "Used in the feature file, 3 places", nil when it is not used.
    var usesNotice: String? {
        let uses = featureUses
        return uses == 0 ? nil : "Used in the feature file, \(uses) place\(uses == 1 ? "" : "s")."
    }

    /// btn:[Rename Glyph Only] (btn:[Rename] when the feature file does not use the name), or
    /// with `inFeatureFile` btn:[Rename in Feature File].  False, with the reason, when refused.
    @discardableResult
    func commit(inFeatureFile: Bool) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed != oldName else { return true }
        guard GlyphNaming.isValid(trimmed) else {
            problem = "“\(trimmed)” is not a valid glyph name."
            return false
        }
        guard !GlyphIndex(document.state).isNameTaken(trimmed, except: glyph) else {
            problem = "Another glyph is named “\(trimmed)”."
            return false
        }
        _ = perform(RenameGlyph(glyph, to: trimmed, inFeatureFile: inFeatureFile))
        return true
    }

    func renameOnly() -> Bool { commit(inFeatureFile: false) }
    func renameEverywhere() -> Bool { commit(inFeatureFile: true) }
}

struct RenameGlyphSheet: View {
    @Bindable var model: RenameGlyphModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\(model.oldName)”").font(.headline)
            TextField("Name", text: $model.name).accessibilityIdentifier("renameGlyph.name")
            if let notice = model.usesNotice { Text(notice).font(.caption).accessibilityIdentifier("renameGlyph.uses") }
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                if model.usesNotice != nil {
                    Button("Rename Glyph Only", action: SheetButtons.closing(model.renameOnly, close)).accessibilityIdentifier("renameGlyph.only")
                    Button("Rename in Feature File", action: SheetButtons.closing(model.renameEverywhere, close)).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("renameGlyph.everywhere")
                } else {
                    Button("Rename", action: SheetButtons.closing(model.renameOnly, close)).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("renameGlyph.ok")
                }
            }
        }
        .padding()
        .frame(width: 400)
    }
}
