import AppKit
import SwiftUI
import WTModel

/// The features of TYPE-005 ... IO-037 built together: installed after the type and drawing
/// features (replacing their catalog stubs), and the per-window hooks attached to each document
/// window as it opens.
extension AppDelegate {
    func installExtras() {
        let documents = documents!
        let window: @MainActor () -> DocumentWindowController? = { documents.activeWindowController }
        commands.remove(Set(SpecialCharacter.allCases.map(SpecialCharacterFeatures.id)))
        var all = SpecialCharacterFeatures.commands(window: window)
        all += TextBlockFeatures.commands(window: window)
        all += FontStyleCommands.commands(window: window)
        all += installFontControls(window: window)
        all += TextAttributeClipboard.commands(edit: editMenu, window: window)
        all.append(installShare(window: window))
        all += ChartPictographs.commands(commands, window: window)
        all.append(ReadingOrderFeatures.command(window: window))
        for command in all { commands.replace(command) }
        for descriptor in TextBlockFeatures.extensions(existing: toolbars.extensions, window: window) + ChartPictographs.extensions(existing: toolbars.extensions, window: window) {
            toolbars.extensions.replace(descriptor)
        }
        ExtraSections.register(into: .standard)
        let styles = StylesPanelModel(selection: activeSelection)
        let preferences = preferences
        styles.autoApply = { preferences[PreferenceCatalog.Object.autoApplyStyles] }
        ObjectStyleRow.shared = styles
    }

    /// menu:File[Share] and the Services bridge (IO-037).
    func installShare(window: @escaping @MainActor () -> DocumentWindowController?) -> Command {
        let share = ShareExport.instances[ObjectIdentifier(self)] ?? ShareExport(quickExport: quickExport)
        ShareExport.instances[ObjectIdentifier(self)] = share
        ServicesRequestor.register()
        let documents = documents!
        let imports = imports
        let edit = editMenu
        let library = library
        let provider = ServicesProvider(window: window, place: { pasteboard, target in
            await ServicesProvider.place(pasteboard, on: target, imports: imports, edit: edit)
        }, choose: { done in
            ServiceChooser.present(documents: library.cache.recentDocuments.map { ($0.id, $0.name) }, open: { id in
                let entry = id.flatMap { id in library.cache.recentDocuments.first { $0.id == id } } ?? library.createDocument()
                return documents.open(documents.environment.makeDocument(id: entry.id, title: entry.name))
            }, done: done)
        })
        ServicesProvider.shared = provider
        NSApp.servicesProvider = provider
        return share.command(window: window)
    }

    func attachExtras(_ window: DocumentWindowController) {
        ExtrasWindowParts.attach(window)
    }
}

/// One window's hooks: the canvas's text keys, the ruler's double-click, the invisibles overlay,
/// the text block handles and the deselection watch.
@MainActor
final class ExtrasWindowParts {
    private struct Entry {
        weak var window: DocumentWindowController?
        let parts: ExtrasWindowParts
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]
    let handles: TextBlockHandles
    private(set) var deselection: SelectionModel.ObservationToken?
    private(set) var requestor: ServicesRequestor?

    init(handles: TextBlockHandles) {
        self.handles = handles
    }

    static func parts(of window: DocumentWindowController) -> ExtrasWindowParts? {
        guard let entry = entries[ObjectIdentifier(window)], entry.window === window else { return nil }
        return entry.parts
    }

    @discardableResult
    static func attach(_ window: DocumentWindowController) -> ExtrasWindowParts {
        if let existing = parts(of: window) { return existing }
        let handles = TextBlockHandles()
        let preferences = window.environment.preferences
        handles.hiddenBlock = { [weak window] in
            guard let window, window.canvas.toolManager?.textInput != nil else { return nil }
            return TextBlockHandles.hiddenBlock(rulersShown: TypeWindowParts.parts(of: window)?.rulers.isShown ?? true,
                                                showHandles: preferences[PreferenceCatalog.Text.handlesWithoutRuler],
                                                editing: window.objectEditing.textSession?.node)
        }
        let result = ExtrasWindowParts(handles: handles)
        entries[ObjectIdentifier(window)] = Entry(window: window, parts: result)
        window.canvas.textKeys = { [weak window] event in
            guard let window else { return false }
            return SpecialCharacterFeatures.handle(event, window: window)
        }
        window.canvas.textContextMenu = { [weak window] _, point in
            window.flatMap { SpellingContextMenu.menu(at: point, in: $0) }
        }
        TypeWindowParts.parts(of: window)?.rulers.view.onDoubleClick = { [weak window] position in
            if let window { TabSheets.editTab(at: position, window: window) }
        }
        window.canvas.overlayExtras.append { [weak window] ctx, viewport in
            guard let window else { return }
            InvisibleMarks.draw(in: ctx, viewport: viewport, window: window)
        }
        window.toolManager.handleLayers.append(handles)
        let charts = ChartElementHandles { [weak window] in window?.toolManager.activeToolID == PointerTool.subselectID }
        window.toolManager.handleLayers.insert(charts, at: 0)
        ChartElementPicks.of(window.documentHandle).onChange = { [weak window] in window?.canvas.setNeedsOverlayDisplay() }
        let requestor = ServicesRequestor(window: window)
        result.requestor = requestor
        window.canvas.servicesRequestor = { [weak requestor] send, back in requestor?.requestor(sendType: send, returnType: back) }
        result.deselection = TextBlockFeatures.watchDeselection(window)
        return result
    }
}

/// The Object panel sections of these tasks.
@MainActor
enum ExtraSections {
    static func register(into registry: InspectorRegistry) {
        registry.register(InspectorSection(id: "textSpacing", order: 66, kinds: [.text, .instance]) { model in
            model.spacing.map { AnyView(SpacingSectionView(section: $0, model: model)) }
        })
        registry.register(InspectorSection(id: "chartElement", order: 70, kinds: [.chart]) { model in
            model.chartElement.map { AnyView(ChartElementSectionView(section: $0, model: model)) }
        })
        registry.register(InspectorSection(id: "textVariations", order: 60, kinds: [.text]) { model in
            model.variations.map { AnyView(VariationSectionView(section: $0, model: model)) }
        })
    }
}
