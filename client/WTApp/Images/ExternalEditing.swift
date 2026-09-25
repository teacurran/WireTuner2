import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTInterchange
import WTModel
import WTProto

/// Watches one file for saves, including an editor's save by atomic rename (the file replaced by a
/// new one): its own descriptor for writes, and its folder for the rename that swaps it.
final class FileWatch: @unchecked Sendable {
    private var sources: [DispatchSourceFileSystemObject] = []
    private let queue = DispatchQueue(label: "wiretuner.external-edit")
    let url: URL
    private let changed: @Sendable () -> Void

    init(url: URL, changed: @escaping @Sendable () -> Void) {
        self.url = url
        self.changed = changed
    }

    /// Starts (or restarts, after the file was swapped) watching.
    func start() {
        queue.sync { rearm() }
    }

    private func rearm() {
        sources.forEach { $0.cancel() }
        sources = []
        for (path, mask) in [(url.path, DispatchSource.FileSystemEvent([.write, .extend, .rename, .delete])),
                             (url.deletingLastPathComponent().path, DispatchSource.FileSystemEvent.write)] {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: queue)
            source.setEventHandler { [weak self] in self?.fired(source.data) }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    private func fired(_ event: DispatchSource.FileSystemEvent) {
        if !event.isDisjoint(with: [.rename, .delete]) { rearm() }
        changed()
    }

    func stop() {
        queue.sync {
            sources.forEach { $0.cancel() }
            sources = []
        }
    }

    deinit {
        sources.forEach { $0.cancel() }
    }
}

/// One image being edited in another application (external-editors.adoc; IMG-019): the image's
/// pixels copied to a file of its own, opened in the editor, and watched; every save (settled for
/// `debounce`) replaces the image's pixels keeping its placed width (`ReplaceEditedImage`), btn:[Done]
/// stops watching and removes the file, btn:[Cancel] puts the original pixels back and removes it.
@MainActor
final class ExternalEditSession: Identifiable {
    let id = UUID()
    let document: DocumentHandle
    let node: OpID
    let appName: String
    let file: URL
    let original: Wiretuner_Doc_V1_PixelSource
    let originalDPI: (x: Double, y: Double)
    /// Stores a new blob so it draws and uploads (the import's blob placement in the app).
    var store: @MainActor (ImportedBlob, DocumentHandle) async throws -> Void = { _, _ in }
    var debounce: Duration = .milliseconds(300)
    private(set) var replacements = 0
    private var lastHash: Data?
    private var pending: Task<Void, Never>?
    private var watch: FileWatch?

    init(document: DocumentHandle, node: OpID, appName: String, file: URL, original: Wiretuner_Doc_V1_PixelSource, dpi: (x: Double, y: Double)) {
        self.document = document
        self.node = node
        self.appName = appName
        self.file = file
        self.original = original
        originalDPI = dpi
        lastHash = original.blobSha256
    }

    /// The image's name for the panel.
    var name: String { document.state.displayName(of: node) }

    /// Writes the original to the file and starts watching it.
    func start(data: Data) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        let watch = FileWatch(url: file) { [weak self] in
            Task { @MainActor in self?.fileDidChange() }
        }
        watch.start()
        self.watch = watch
    }

    /// A save (or several in a row): read once they settle.
    func fileDidChange() {
        pending?.cancel()
        let debounce = debounce
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    /// Reads the file and, when its pixels changed, replaces the image's.
    @discardableResult
    func reload() async -> Bool {
        guard let data = try? Data(contentsOf: file), let decoded = try? ImageImporter().decode(data, name: file.lastPathComponent) else { return false }
        let pixels = EditedImagePixels.source(decoded.pixels)
        guard pixels.blobSha256 != lastHash else { return false }
        lastHash = pixels.blobSha256
        try? await store(decoded.pixels.blob, document)
        _ = await document.perform(ReplaceEditedImage(node, pixels: pixels)).value
        replacements += 1
        return true
    }

    /// btn:[Done].
    func done() {
        finish()
    }

    /// btn:[Cancel]: the original pixels and resolution back.
    @discardableResult
    func cancel() -> Task<Wiretuner_Doc_V1_Change?, Never> {
        finish()
        return document.perform(ReplaceEditedImage(node, pixels: original, dpi: originalDPI))
    }

    private func finish() {
        pending?.cancel()
        watch?.stop()
        watch = nil
        try? FileManager.default.removeItem(at: file)
    }
}

/// Edit With… (external-editors.adoc; IMG-019): menu:Edit[Edit With] lists the applications that
/// open images, the Object panel's btn:[Edit With…] and kbd:[Option]-double-click on an image use
/// the *Default image editor* (else the system's), a confirmation first while *Confirm before
/// editing externally* is on, and the *Editing in* panel lists the sessions with Done and Cancel.
@MainActor
@Observable
final class ExternalEditing {
    static let shared = ExternalEditing()
    static let noImage = "Select one image"
    static let menu = "Edit With"

    private(set) var sessions: [ExternalEditSession] = []
    @ObservationIgnored var window: @MainActor () -> DocumentWindowController? = { nil }
    @ObservationIgnored var preferences: PreferenceStore?
    /// The blob cache: the file a hash is kept in, and storing new ones.
    @ObservationIgnored var cached: @MainActor (Data) -> Data? = { _ in nil }
    @ObservationIgnored var store: @MainActor (ImportedBlob, DocumentHandle) async throws -> Void = { _, _ in }
    /// Opens `file` in the application at `app`.
    @ObservationIgnored var open: @MainActor (URL, URL) -> Void = { file, app in
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    /// The applications that open `type`, and the system's default one.
    @ObservationIgnored var editors: @MainActor (UTType) -> [URL] = { NSWorkspace.shared.urlsForApplications(toOpen: $0) }
    @ObservationIgnored var systemDefault: @MainActor (UTType) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    /// Asks before launching the editor (when the preference says to).
    @ObservationIgnored var confirm: @MainActor (String) -> Bool = { app in
        let alert = NSAlert()
        alert.messageText = "Edit the image in \(app)?"
        alert.informativeText = "Each time you save in \(app), the image in the document is replaced.  Click Done in the Editing panel when you are finished."
        alert.addButton(withTitle: "Edit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    @ObservationIgnored var directory: @MainActor () -> URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "WireTuner/EditSessions")
    }
    /// Shows the panel for `window`.
    @ObservationIgnored var showPanel: @MainActor (DocumentWindowController) -> Void = { _ in }

    init() {}

    /// The one selected image of the front window, with its document.
    func selectedImage() -> (window: DocumentWindowController, node: OpID)? {
        guard let window = window() else { return nil }
        let nodes = window.objectEditing.selectedNodes
        guard nodes.count == 1, window.documentHandle.state.nodeKind(nodes[0]) == .image else { return nil }
        return (window, nodes[0])
    }

    static func type(of pixels: Wiretuner_Doc_V1_PixelSource) -> UTType {
        UTType(pixels.format) ?? .image
    }

    /// The editor a plain Edit With… uses: the *Default image editor* preference, else the
    /// system's application for the image's type.
    func defaultEditor(for pixels: Wiretuner_Doc_V1_PixelSource) -> URL? {
        if let preferences, let chosen = PreferenceBookmarks(store: preferences).url(for: PreferenceCatalog.Object.externalEditor.erased) { return chosen }
        return systemDefault(Self.type(of: pixels))
    }

    /// Starts editing `node` of `window` in `app` (nil: the default editor).
    @discardableResult
    func edit(_ node: OpID, in window: DocumentWindowController, with app: URL? = nil) -> ExternalEditSession? {
        let document = window.documentHandle
        guard case .image(let image)? = document.state.props(node).kind, let editor = app ?? defaultEditor(for: image.pixels),
              let data = cached(image.pixels.blobSha256) else { return nil }
        if let existing = sessions.first(where: { $0.document === document && $0.node == node }) { return existing }
        let appName = FileManager.default.displayName(atPath: editor.path).replacingOccurrences(of: ".app", with: "")
        if preferences?[PreferenceCatalog.Object.confirmExternalEditor] ?? true, !confirm(appName) { return nil }
        let ext = Self.type(of: image.pixels).preferredFilenameExtension ?? "png"
        let file = directory().appending(path: document.id).appending(path: "\(node)-\(ImportedBlob.hex(image.pixels.blobSha256).prefix(8)).\(ext)")
        let session = ExternalEditSession(document: document, node: node, appName: appName, file: file, original: image.pixels, dpi: (image.dpiX, image.dpiY))
        session.store = store
        do { try session.start(data: data) } catch { return nil }
        sessions.append(session)
        open(file, editor)
        showPanel(window)
        return session
    }

    func done(_ session: ExternalEditSession) {
        session.done()
        sessions.removeAll { $0 === session }
    }

    @discardableResult
    func cancel(_ session: ExternalEditSession) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        sessions.removeAll { $0 === session }
        return session.cancel()
    }

    /// Ends every session (the app quits): the files go.
    func finishAll() {
        for session in sessions { session.done() }
        sessions = []
    }

    // MARK: Commands

    /// The Edit With submenu: the applications that open images, each one command.
    func commands() -> [Command] {
        let apps = Array(editors(.image).prefix(12))
        return apps.enumerated().map { index, app in
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            return Command(id: CommandID(rawValue: "edit.editWith.\(index)"), title: name, menu: MenuPath(StandardCommands.Menu.edit, Self.menu, section: 1),
                           keywords: ["edit", "external", "editor", "image"],
                           validation: { [weak self] in self?.selectedImage() == nil ? .disabled(Self.noImage) : .enabled },
                           action: .perform { [weak self] in
                               guard let self, let (window, node) = self.selectedImage() else { return }
                               self.edit(node, in: window, with: app)
                           })
        }
    }

    /// The Object panel's btn:[Edit With…] under the image rows.
    static func register(into registry: InspectorRegistry, editing: ExternalEditing = .shared) {
        registry.register(InspectorSection(id: "imageEdit", order: 74, kinds: [.image]) { panel in
            guard panel.objects.count == 1 else { return nil }
            return AnyView(Button("Edit With…") { editing.editFromPanel() }.accessibilityIdentifier("object.image.editWith").padding(.horizontal))
        })
    }

    /// btn:[Edit With…] and kbd:[Option]-double-click: the selected image in the default editor.
    @discardableResult
    func editFromPanel() -> ExternalEditSession? {
        guard let (window, node) = selectedImage() else { return nil }
        return edit(node, in: window)
    }
}

/// The *Editing in* panel: each session with btn:[Done] and btn:[Cancel].
struct EditingInPanel: View {
    let editing: ExternalEditing
    let document: DocumentHandle

    static func finishing(_ editing: ExternalEditing, _ session: ExternalEditSession) -> () -> Void { { editing.done(session) } }
    static func cancelling(_ editing: ExternalEditing, _ session: ExternalEditSession) -> () -> Void { { editing.cancel(session) } }

    var body: some View {
        let sessions = editing.sessions.filter { $0.document === document }
        VStack(alignment: .leading, spacing: 6) {
            if sessions.isEmpty {
                Text("No images are being edited.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                HStack {
                    Text("Editing \u{201C}\(session.name)\u{201D} in \(session.appName)").lineLimit(1)
                    Spacer()
                    Button("Cancel", action: Self.cancelling(editing, session)).accessibilityIdentifier("editingIn.cancel")
                    Button("Done", action: Self.finishing(editing, session)).accessibilityIdentifier("editingIn.done")
                }
            }
        }
        .padding(10)
        .frame(width: 360)
    }

    /// The panel as a child window of `window`, shown while it has sessions.
    static func show(for window: DocumentWindowController, editing: ExternalEditing) -> NSPanel? {
        guard let parent = window.window else { return nil }
        if let existing = parent.childWindows?.first(where: { $0.identifier?.rawValue == "editing-in" }) as? NSPanel {
            existing.orderFront(nil)
            return existing
        }
        let panel = NSPanel(contentViewController: NSHostingController(rootView: EditingInPanel(editing: editing, document: window.documentHandle)))
        panel.identifier = NSUserInterfaceItemIdentifier("editing-in")
        panel.title = "Editing"
        panel.styleMask = [.titled, .utilityWindow, .closable]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        parent.addChildWindow(panel, ordered: .above)
        return panel
    }
}
