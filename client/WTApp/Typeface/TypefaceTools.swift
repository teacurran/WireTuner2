import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The typeface tools of FONT-014, FONT-017 and FONT-021: menu:Glyph[Find Problems…] and its panel,
/// menu:View[Preview Strip] and the strip on each glyph tab, and menu:Font[Kerning Classes…],
/// *Auto Kern…*, *Add to Left Class* and *Add to Right Class*.
@MainActor
enum TypefaceTools {
    enum ID {
        static let findProblems: CommandID = "glyph.findProblems"
        static let kerningClasses: CommandID = "font.kerningClasses"
        static let autoKern: CommandID = "font.autoKern"
        static let addToLeftClass: CommandID = "font.addToLeftClass"
        static let addToRightClass: CommandID = "font.addToRightClass"
    }

    static let panelID: PanelID = "findProblems"
    static let panelGroup = "Find Problems"

    /// The document of `window`'s font (a glyph tab's parent document).
    static func fontDocument(_ window: DocumentWindowController, features: TypefaceFeatures) -> DocumentHandle {
        features.gridDocument(of: window)
    }

    /// *Add to Left Class* / *Right Class*: the target glyphs join the class of their first glyph on
    /// that side, or a new class named after it.
    static func addToClass(_ side: KernSide, glyphs: [OpID], in document: DocumentHandle) -> (any WTModel.Command)? {
        guard let first = glyphs.first else { return nil }
        let kerning = Kerning(document.state)
        if let existing = kerning.kernClass(of: first, side: side) {
            let rest = glyphs.filter { !existing.members.contains($0) }
            return rest.isEmpty ? nil : EditKernClass(existing.id, .addMembers(rest))
        }
        let name = GlyphIndex(document.state)[first]?.name ?? "class"
        return CreateKernClass(name, side: side, members: glyphs)
    }

    @discardableResult
    static func presentClasses(on window: DocumentWindowController, features: TypefaceFeatures) -> NSWindow? {
        let document = fontDocument(window, features: features)
        let model = KerningClassesModel(document: document) { window.objectEditing.perform($0) }
        return window.presentSheet("kerning-classes") { close in
            KerningClassesSheet(model: model) {
                model.stop()
                close()
            }
        }
    }

    @discardableResult
    static func presentAutoKern(on window: DocumentWindowController, features: TypefaceFeatures) -> NSWindow? {
        let document = fontDocument(window, features: features)
        let model = AutoKernModel(document: document, glyphs: features.targetGlyphs(in: window)) { window.objectEditing.perform($0) }
        return window.presentSheet("auto-kern") { close in AutoKernSheet(model: model, close: close) }
    }

    static func panel(selection: ActiveSelection?, features: TypefaceFeatures, window: @escaping @MainActor () -> DocumentWindowController?) -> PanelDescriptor {
        let model = FindProblemsModel(selection: selection)
        model.openGlyph = { glyph in if let front = window() { features.openGlyph(glyph, from: front) } }
        model.selectInGrid = { glyphs in
            guard let front = window(), let grid = features.gridWindow(of: fontDocument(front, features: features).id) else { return }
            features.mode(of: grid)?.grid?.model.select(glyphs)
        }
        return PanelDescriptor(id: panelID, title: "Find Problems", icon: "exclamationmark.triangle", defaultGroup: panelGroup, menuOrder: 95,
                               helpSlug: "glyph-editing") {
            FindProblemsView(model: model)
        }
    }

    static func commands(features: TypefaceFeatures, window: @escaping @MainActor () -> DocumentWindowController?, showPanel: @escaping @MainActor () -> Void) -> [Command] {
        let typeface: @MainActor @Sendable () -> CommandValidation = {
            guard let front = window() else { return .disabled(TypefaceFeatures.noDocument) }
            return DocumentKind(front.documentHandle.state) == .typeface ? .enabled : .disabled(TypefaceFeatures.notTypeface)
        }
        let glyphs: @MainActor @Sendable () -> CommandValidation = {
            guard let front = window(), DocumentKind(front.documentHandle.state) == .typeface else { return .disabled(TypefaceFeatures.notTypeface) }
            return features.targetGlyphs(in: front).isEmpty ? .disabled(TypefaceFeatures.noGlyph) : .enabled
        }
        func add(_ side: KernSide) -> CommandAction {
            .perform {
                guard let front = window(), let command = addToClass(side, glyphs: features.targetGlyphs(in: front), in: fontDocument(front, features: features)) else { return }
                front.objectEditing.perform(command)
            }
        }
        let font = TypefaceFeatures.Menu.font
        return [
            Command(id: ID.findProblems, title: "Find Problems…", menu: MenuPath(TypefaceFeatures.Menu.glyph, section: 3), keywords: ["check", "validate", "problems"],
                    validation: typeface, action: .perform(showPanel)),
            Command(id: ID.kerningClasses, title: "Kerning Classes…", key: KeyEquivalent("k", [.command, .option]), menu: MenuPath(font, section: 1),
                    keywords: ["kerning", "classes"], validation: typeface,
                    action: .perform { if let front = window() { presentClasses(on: front, features: features) } }),
            Command(id: ID.autoKern, title: "Auto Kern…", menu: MenuPath(font, section: 1), keywords: ["kerning", "automatic"], validation: typeface,
                    action: .perform { if let front = window() { presentAutoKern(on: front, features: features) } }),
            Command(id: ID.addToLeftClass, title: "Add to Left Class", menu: MenuPath(font, section: 1), keywords: ["kerning", "class"], validation: glyphs,
                    action: add(.left)),
            Command(id: ID.addToRightClass, title: "Add to Right Class", menu: MenuPath(font, section: 1), keywords: ["kerning", "class"], validation: glyphs,
                    action: add(.right)),
            PreviewStripHost.command(window: window),
        ]
    }
}
