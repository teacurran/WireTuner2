import AppKit
import SwiftUI
import WTModel

/// The commands, panels and sections of the type, drawing, typeface and export tasks built together
/// (TYPE-011 ... FONT-021): installed after the other features, each replacing its catalog stub,
/// and the per-window parts attached to each document window as it opens.
@MainActor
final class TypeWindowParts {
    let rulers: TextRulers
    let spelling: TypingSpelling
    let removedText: RemovedTextNotice

    init(rulers: TextRulers, spelling: TypingSpelling, removedText: RemovedTextNotice) {
        self.rulers = rulers
        self.spelling = spelling
        self.removedText = removedText
    }

    /// A window's parts, keyed by its identifier and holding the window weakly: a closed window's
    /// address can be reused by the next window, so an entry counts only while its window is that
    /// same object (a stale entry is replaced, never handed over).
    struct Entry {
        weak var window: DocumentWindowController?
        let parts: TypeWindowParts
    }

    static var entries: [ObjectIdentifier: Entry] = [:]

    static func parts(of window: DocumentWindowController) -> TypeWindowParts? {
        guard let entry = entries[ObjectIdentifier(window)], entry.window === window else { return nil }
        return entry.parts
    }

    /// Attaches the text ruler, the spelling underlines and the text colour drop to `window`.
    @discardableResult
    static func attach(_ window: DocumentWindowController, preferences: PreferenceStore) -> TypeWindowParts {
        if let existing = parts(of: window) { return existing }
        entries = entries.filter { $0.value.window != nil }
        let rulers = TextRulers(window: window, defaults: preferences.defaults)
        rulers.tracksLine = { preferences[PreferenceCatalog.Text.trackTabLine] }
        let spelling = TypingSpelling(window: window, checker: { SpellingChecker(service: SpellingFeatures.shared.model.service, options: SpellingOptions(preferences: preferences)) },
                                      isOn: { preferences[PreferenceCatalog.Spelling.checkWhileTyping] })
        let removedText = RemovedTextNotice(window: window)
        let result = TypeWindowParts(rulers: rulers, spelling: spelling, removedText: removedText)
        entries[ObjectIdentifier(window)] = Entry(window: window, parts: result)
        let previous = window.onClose
        window.onClose = { closed in
            previous?(closed)
            detach(closed)
        }
        window.canvas.overlayExtras.append { [weak rulers, weak spelling, weak window, weak removedText, weak result] ctx, viewport in
            // The parts hold their window unowned: once the window is gone they are never touched
            // (a canvas layer can still draw while the closed window's controller deallocates).
            guard let window, let result, parts(of: window) === result else { return }
            removedText?.track()
            spelling?.draw(in: ctx, viewport: viewport)
            rulers?.drawTracking(in: ctx, viewport: viewport)
            // The ruler follows the block, and VoiceOver's description the selection, once the
            // overlay has drawn (not while it draws).
            Task { @MainActor [weak window, weak result] in
                guard let window, let result, parts(of: window) === result else { return }
                rulers?.update()
                CanvasDescriptions.update(window)
            }
        }
        window.canvas.textColorDrop = { [weak window] pasteboard, point in
            guard let window else { return false }
            let space: RenderColor.Space = preferences[PreferenceCatalog.Colors.defaultColorSpace] == "srgb" ? .sRGB : .displayP3
            return TextColorDrop(window: window).drop(pasteboard, at: point, defaultSpace: space) != nil
        }
        return result
    }

    static func detach(_ window: DocumentWindowController) {
        guard let entry = entries[ObjectIdentifier(window)], entry.window === window || entry.window == nil else { return }
        entry.parts.removedText.stop()
        entries[ObjectIdentifier(window)] = nil
    }

    /// menu:View[Text Rulers]: shown or hidden in every window.
    static func textRulersCommand(defaults: UserDefaults, window: @escaping @MainActor () -> DocumentWindowController?) -> Command {
        Command(id: StandardCommands.ID.textRulers, title: "Text Rulers",
                menu: MenuPath(StandardCommands.Menu.view, section: StandardCommands.Section.viewRulers), keywords: ["rulers", "tabs"],
                validation: { .checked(defaults.object(forKey: TextRulers.shownKey) as? Bool ?? true) },
                action: .perform {
                    defaults.set(!(defaults.object(forKey: TextRulers.shownKey) as? Bool ?? true), forKey: TextRulers.shownKey)
                    if let front = window() { parts(of: front)?.rulers.update() }
                })
    }
}

extension AppDelegate {
    func installTypeAndDrawingFeatures() {
        let documents = documents!
        let window: @MainActor () -> DocumentWindowController? = { documents.activeWindowController }
        TextEditorFeatures.shared.install(into: commands, window: window)
        var all = FindTextFeatures.shared.commands(window: window)
        all += SpellingFeatures.shared.commands(window: window, preferences: preferences)
        all += TextWrapFeatures.commands(window: window)
        all.append(TypeWindowParts.textRulersCommand(defaults: preferences.defaults, window: window))
        all += ChartFeatures.commands(window: window)
        all += TextStyleOperations.commands(window: window, preferences: preferences)
        let typeface = typeface
        // Closed at first launch, like the other tool panels.
        panels.groupDefaults[TypefaceTools.panelGroup] = PanelGroupDefaults(position: 10, isOpen: false)
        panels.registerIfAbsent(TypefaceTools.panel(selection: activeSelection, features: typeface, window: window))
        all += TypefaceTools.commands(features: typeface, window: window) { [layout] in layout.showPanel(TypefaceTools.panelID) }
        let layout = layout
        all.append(GraphicReplaceCommands.command { layout.showPanel("findReplace") })
        all += quickExport.commands(window: window)
        all.append(ExportPresetManagerView.command(store: exports.presets, window: window))
        for command in all { commands.replace(command) }
        TypeSections.register(into: .standard)
        for descriptor in DrawingToolDelivery.descriptors(store: preferences, window: window) { tools.replace(descriptor) }
        toolPalette.presentOptions = ChartFeatures.toolOptions(window: window, previous: toolPalette.presentOptions)
        installHelp()
        toolPalette.reload(from: tools)
    }

    func attachTypeAndDrawingFeatures(_ window: DocumentWindowController) {
        TypeWindowParts.attach(window, preferences: preferences)
        DragExport.attach(window, preferences: preferences)
        let typeface = typeface
        PreviewStripHost.attach(window, preferences: preferences) { [weak window] glyph in
            if let window { typeface.openGlyph(glyph, from: window) }
        }
    }

    /// The Help panel with the bundled guide and *What's here* (BASIC-007).
    func installHelp() {
        let browser = HelpBrowserModel()
        panels.registerIfAbsent(HelpFeatures.descriptor(help: helpModel, browser: browser))
        let hover = HelpHover(tools: tools, panels: panels, model: browser)
        hover.start()
        HelpFeatures.hovers[ObjectIdentifier(self)] = hover
    }

    /// menu:File[Quick Export] over the app's exports (IO-015).
    var quickExport: QuickExport {
        if let existing = QuickExport.instances[ObjectIdentifier(self)] { return existing }
        let made = QuickExport(exports: exports, preferences: preferences)
        QuickExport.instances[ObjectIdentifier(self)] = made
        return made
    }
}

/// The Calligraphic Pen, the Eraser and the Chart tool, each replacing its catalog placeholder
/// with its options sheet (DRAW-019, DRAW-029, DRAW-033).
@MainActor
enum DrawingToolDelivery {
    static func descriptors(store: PreferenceStore, window: @escaping @MainActor () -> DocumentWindowController?) -> [ToolDescriptor] {
        func delivered(_ id: ToolID, keys: [AnyPreferenceKey], _ make: @escaping @MainActor @Sendable () -> any Tool) -> ToolDescriptor {
            var descriptor = ToolCatalog.all.first { $0.id == id }!.delivering(make)
            let title = descriptor.title
            descriptor.options = { ToolOptionSheets.controller(title: title, keys: keys, store: store) }
            return descriptor
        }
        return [
            delivered(CalligraphicPen.id, keys: CalligraphicPreferences.sheet) { CalligraphicPen { CalligraphicSettings(preferences: store) } },
            delivered(EraserTool.id, keys: EraserPreferences.sheet) { EraserTool { EraserSettings(preferences: store) } },
            ChartFeatures.descriptor(window: window),
        ]
    }
}

/// The Object panel sections of these tasks.
@MainActor
enum TypeSections {
    static func register(into registry: InspectorRegistry) {
        registry.register(InspectorSection(id: "textParagraph", order: 65, kinds: [.text, .instance]) { model in
            model.paragraph.map { AnyView(ParagraphSectionView(section: $0, model: model)) }
        })
    }
}
