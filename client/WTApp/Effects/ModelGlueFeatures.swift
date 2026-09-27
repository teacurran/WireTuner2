import AppKit
import WTModel

/// The app half of this build's model features, installed by `AppDelegate` in one call: the
/// Envelope menu, toolbar and presets with the outline handles (FX-039), the Text menu's and Object
/// panel's text-on-path commands (TYPE-017 for TYPE-041), menu:View[Perspective Grid] with the grid
/// overlay, the Define Grids sheet and the Perspective tool (FX-043, FX-044), menu:View[Show Links]
/// (WEB-004), the path clean-ups (Simplify, Correct Direction, Fractalize; DRAW-030, FX-031) and
/// the Inspect panel's snippets (COLLAB-036), and Transparency, Expand Stroke and Inset Path with
/// their sheets (OBJ-026, OBJ-029, OBJ-030).
@MainActor
final class ModelGlueFeatures {
    let preferences: PreferenceStore
    private(set) var envelopes: EnvelopeFeatures?
    private(set) var perspective: PerspectiveFeatures?
    private(set) var links: LinkOverlayFeatures?
    private(set) var pathAlter: PathAlterFeatures?
    private(set) var pathOperations: PathOperationFeatures?
    let inspect: InspectPanelModel

    init(preferences: PreferenceStore) {
        self.preferences = preferences
        inspect = InspectPanelModel(defaults: preferences.defaults)
    }

    func install(commands: CommandRegistry, panels: PanelRegistry, extensions: ExtensionRegistry,
                 window: @escaping @MainActor () -> DocumentWindowController?) {
        let target: ObjectMenuCommands.Target = { window()?.objectEditing }
        let envelopes = EnvelopeFeatures(target: target, store: preferences)
        envelopes.install(commands: commands)
        self.envelopes = envelopes
        TextOnPathMenu.install(into: commands, target: target)
        let perspective = PerspectiveFeatures(window: window)
        perspective.install(commands: commands)
        self.perspective = perspective
        let links = LinkOverlayFeatures(window: window)
        links.install(commands: commands)
        self.links = links
        let pathAlter = PathAlterFeatures(target: target, store: preferences)
        pathAlter.install(commands: commands, extensions: extensions)
        self.pathAlter = pathAlter
        let pathOperations = PathOperationFeatures(target: target, store: preferences)
        pathOperations.install(commands: commands, extensions: extensions)
        self.pathOperations = pathOperations
        inspect.window = window
        inspect.attach(preferences: preferences)
        panels.groupDefaults[InspectPanel.group] = panels.groupDefaults[InspectPanel.group] ?? PanelGroupDefaults(position: 12, isOpen: false)
        panels.registerIfAbsent(InspectPanel.descriptor(model: inspect))
        // Inspecting a collaborator's selection (COLLAB-037): the command and the name-tag click.
        let inspect = inspect
        let inspectRemote: @MainActor (DocumentWindowController, RemoteParticipant) -> Void = { window, participant in
            window.environment.layout.showPanel(InspectPanel.id)
            inspect.inspect(participant)
        }
        commands.replace(RemoteSelectionInspection.command(window: window, inspect: inspectRemote))
        InspectTool.nameTagClicked = inspectRemote
    }

    /// A document window opened: the grid overlay, the link overlay and the Inspect panel follow it
    /// (its selection, its document's changes, its collaborators' presence).
    func attach(_ window: DocumentWindowController) {
        perspective?.attach(window)
        links?.attach(window)
        let inspect = inspect
        let previous = window.onSelectionChange
        window.onSelectionChange = { window in
            previous?(window)
            inspect.selectionDidChange()
        }
        window.documentHandle.observe { _ in inspect.documentDidChange() }
        window.presence.observe { inspect.presenceDidChange() }
    }
}

extension AppDelegate {
    /// The Perspective tool in place of its catalog stub (before the Tools panel reads the registry).
    func installModelGlueTools() {
        tools.replace(PerspectiveTool.descriptor)
    }

    func installModelGlue() {
        let documents = documents!
        modelGlue.inspect.blob = { [imports] in imports.blobs.cached($0) }
        modelGlue.install(commands: commands, panels: panels, extensions: toolbars.extensions) { documents.activeWindowController }
        modelGlue.links?.index = { [unowned self] window in web.attach(window).links }
        exports.commentAuthor = { [unowned self] window, account in comments.attach(window).name(of: account) }
    }

    func attachModelGlue(_ window: DocumentWindowController) {
        modelGlue.attach(window)
    }
}
