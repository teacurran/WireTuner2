import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTInterchange
import WTModel
import WTProto
import WTRender
import WTSync

/// What the web features keep per window: the document's link index, updated from every applied
/// change (`LinkIndex.apply`; urls.adoc, "Client"), the links *Find* last selected, and the
/// animation transport (the frame shown, playing or not -- per window and never in the document).
@MainActor
@Observable
final class WindowWeb {
    @ObservationIgnored weak var window: DocumentWindowController?
    @ObservationIgnored let document: DocumentHandle
    private(set) var links = LinkIndex()
    private(set) var revision = 0
    /// What *Find* selected, for *Update everywhere*: the link and its uses.
    @ObservationIgnored var found: (url: String, uses: LinkUses)?
    @ObservationIgnored private var observation: DocumentHandle.ObservationToken?
    /// The frame the canvas previews (nil: the whole document).
    private(set) var frameIndex: Int?
    @ObservationIgnored private var playback: CanvasPlayback?
    /// Whether the frames are playing (a run that does not loop stops on its last frame).
    var isPlaying: Bool { playback?.player.isPlaying == true }
    /// Makes the ticker playback runs on (the canvas's display link in the app).
    @ObservationIgnored var makeTicker: @MainActor (CanvasView) -> PlaybackTicker = { DisplayLinkTicker(view: $0) }

    init(window: DocumentWindowController) {
        self.window = window
        document = window.documentHandle
    }

    func install() {
        links = LinkIndex(document.state)
        observation = document.observe { [weak self] change in self?.documentDidChange(change) }
    }

    func tearDown() {
        if let observation { document.stopObserving(observation) }
        observation = nil
        stop()
        window?.canvas.endPreview()
    }

    /// Every applied change updates the index from the nodes its ops name.
    func documentDidChange(_ change: ContentChange) {
        if let applied = change.change {
            links.apply(applied, state: document.state)
        } else {
            links = LinkIndex(document.state)
        }
        revision += 1
    }

    // MARK: Animation transport (WEB-017)

    var info: AnimationInfo { AnimationInfo(document.state) }
    var frames: [AnimationFrame] { info.frames(pages: document.pages) }

    /// "7 / 24", or "No frames".
    var counter: String {
        let count = frames.count
        guard count > 0 else { return "No frames" }
        return "\((frameIndex ?? 0) + 1) / \(count)"
    }

    /// Shows frame `index` on the canvas (stopping playback).
    func show(_ index: Int) {
        let frames = frames
        guard !frames.isEmpty, let canvas = window?.canvas else { return }
        stop()
        let clamped = min(max(index, 0), frames.count - 1)
        frameIndex = clamped
        canvas.previewFrame = frames[clamped]
        revision += 1
    }

    /// Steps by `delta` frames, wrapping when the document loops.
    func step(_ delta: Int) {
        let count = frames.count
        guard count > 0 else { return }
        let target = (frameIndex ?? 0) + delta
        show(info.loop ? ((target % count) + count) % count : target)
    }

    func first() { show(0) }
    func last() { show(frames.count - 1) }

    /// Play or stop.
    func togglePlay() {
        isPlaying ? stop() : play()
    }

    func play() {
        guard let canvas = window?.canvas, !isPlaying else { return }
        guard let playback = canvas.startPlayback(ticker: makeTicker(canvas)) else { return }
        if let frameIndex { playback.player.seek(to: frameIndex); playback.player.play() }
        playback.player.onFrame = { [weak self, weak canvas] index in
            canvas?.previewFrame = playback.frames[index]
            self?.frameIndex = index
            self?.revision += 1
        }
        self.playback = playback
        revision += 1
    }

    /// Stops playback; the current frame stays until the canvas is clicked.
    func stop() {
        guard let playback else { return }
        playback.player.stop()
        self.playback = nil
        revision += 1
    }

    /// Back to the whole document.
    func endPreview() {
        stop()
        frameIndex = nil
        window?.canvas.endPreview()
        revision += 1
    }

    /// The layer of the frame shown (the Layers panel highlights it).
    var currentLayer: OpID? {
        guard let frameIndex, frames.indices.contains(frameIndex), let layer = frames[frameIndex].layers.last else { return nil }
        return OpID(layer)
    }
}

/// The web features of the WEB epic's client-ui tasks: the Navigation panel (WEB-002, with
/// WEB-021's *On click* slot), the Animation panel and its shortcuts (WEB-017), the SVG Animation
/// section of the Object panel (WEB-027), menu:Extensions[Animate > Release to Layers…] (WEB-015's
/// sheet), menu:File[Publish as HTML…] and the HTML Setup sheet (WEB-009), and *Export Animated
/// SVG…* (WEB-018's entry).
@MainActor
final class WebFeatures {
    enum ID {
        static let publish: CommandID = "file.publishHTML"
        static let htmlSetup: CommandID = "file.htmlSetup"
        static let exportAnimatedSVG: CommandID = "file.exportAnimatedSVG"
        static let play: CommandID = "animation.play"
        static let nextFrame: CommandID = "animation.next"
        static let previousFrame: CommandID = "animation.previous"
        static let firstFrame: CommandID = "animation.first"
        static let lastFrame: CommandID = "animation.last"
        static let frameHold: CommandID = "layer.frameHold"
        static let excludeFromAnimation: CommandID = "layer.excludeFromAnimation"
    }

    static let navigationPanel: PanelID = "navigation"
    static let animationPanel: PanelID = "animation"
    static let noDocument = DocumentSetupFeatures.noDocument
    static let noFrames = "The document has no animation frames"
    static let noLayer = "Select a layer in the Layers panel"
    static let releaseSheet = "release-to-layers-sheet"
    static let publishSheet = "publish-html-sheet"
    static let setupSheet = "html-setup-sheet"

    let preferences: PreferenceStore
    let panel = WebPanelState()
    var window: @MainActor () -> DocumentWindowController? = { nil }
    /// The blobs a snapshot reads.
    var blobs = BlobPlacement()
    /// Presents a sheet on a window -- on its front sheet when one is open (btn:[Setup…] in the
    /// Publish sheet), since a second sheet on the window waits unseen behind the first
    /// (replaceable in tests).
    var presentSheet: @MainActor (NSWindow, NSWindow?) -> Void = { sheet, parent in
        if let host = ModalUI.host(parent) { host.beginSheet(sheet) } else { sheet.makeKeyAndOrderFront(nil) }
    }
    /// Chooses a folder (the Publish sheet's *Choose…*, the Animated SVG destination).
    var chooseFolder: @MainActor (NSWindow?) async -> URL? = { window in
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        return await ModalUI.urls(panel, on: window).first
    }
    /// The folders chosen here, as security-scoped bookmarks, so the sandboxed app can still
    /// write to a setting's *Location* after a relaunch (the document keeps only the path).
    var folderBookmarks: UserDefaults { preferences.defaults }
    static let folderBookmarkPrefix = "wt.bookmarks.html."

    /// The defaults key of the folder `url`'s bookmark: its path without a trailing slash, so a
    /// folder the open panel returns (`…/Sites/`) and the same folder named in a path
    /// (`…/Sites/Brochure` less its last component) find one key.
    static func folderBookmarkKey(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return folderBookmarkPrefix + path
    }

    /// Remembers access to `url`, a folder the person chose.
    func remember(_ url: URL) {
        guard let data = PreferenceBookmarks.bookmark(for: url) else { return }
        folderBookmarks.set(data, forKey: Self.folderBookmarkKey(url))
    }

    /// The remembered folder that grants access to `path`: its own bookmark or its nearest
    /// remembered ancestor's, resolved (a stale bookmark renewed); nil when none is remembered.
    func bookmarkedFolder(for path: String) -> URL? {
        var candidate = URL(filePath: path).standardizedFileURL
        while candidate.path(percentEncoded: false) != "/" {
            if let data = folderBookmarks.data(forKey: Self.folderBookmarkKey(candidate)) {
                var stale = false
                if let url = PreferenceBookmarks.resolve(data, stale: &stale) {
                    if stale { remember(url) }
                    return url
                }
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    /// `body` run with access to the chosen folder at `path` (or, for a path chosen inside it,
    /// its nearest remembered ancestor).
    func withAccess<T>(to path: String, _ body: () throws -> T) rethrows -> T {
        let url = bookmarkedFolder(for: path)
        let scoped = url?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { url?.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// `body` awaited with access to the chosen folder at `path`: the publish writes off the main
    /// actor while the access lasts.
    func withAccess<T>(to path: String, _ body: () async throws -> T) async rethrows -> T {
        let url = bookmarkedFolder(for: path)
        let scoped = url?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { url?.stopAccessingSecurityScopedResource() } }
        return try await body()
    }

    /// The browsers *Open when done* offers.
    var browsers = BrowserList()
    /// Chooses an application (the browser pop-up's btn:[Other…]).
    var chooseApplication: @MainActor (NSWindow?) async -> URL? = { window in
        let panel = PreferenceBookmarks.openPanel(for: PreferenceCatalog.Export.previewBrowser.erased)
        return await ModalUI.urls(panel, on: window).first
    }
    /// The browser *Open when done* uses: the *Preview browser* preference; nil for the default.
    var browser: URL? {
        get { PreferenceBookmarks(store: preferences).url(for: PreferenceCatalog.Export.previewBrowser.erased) }
        set {
            let bookmarks = PreferenceBookmarks(store: preferences)
            if let newValue { bookmarks.choose(newValue, for: PreferenceCatalog.Export.previewBrowser.erased) } else { bookmarks.clear(PreferenceCatalog.Export.previewBrowser.erased) }
        }
    }
    /// Sees every step of a publish, on the thread doing it (a test holds a publish mid-way).
    var observePublish: @Sendable (HTMLPublishStep) -> Void = { _ in }

    /// Reveals files in the Finder.
    var reveal: @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    /// Opens a file (the published page), in the application at the second URL when one is
    /// chosen, else the default one.
    var open: @MainActor (URL, URL?) -> Void = { url, application in
        if let application {
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
    private var windows: [ObjectIdentifier: (window: DocumentWindowController, web: WindowWeb, closing: NSObjectProtocol?)] = [:]
    private(set) var sheets: [String: NSWindow] = [:]
    /// What each open sheet does when it goes (its models stop observing the document).
    private var teardowns: [String: @MainActor () -> Void] = [:]

    init(preferences: PreferenceStore) {
        self.preferences = preferences
    }

    func install(commands: CommandRegistry, panels: PanelRegistry, extensions: ExtensionRegistry, window: @escaping @MainActor () -> DocumentWindowController?) {
        self.window = window
        panel.window = window
        panel.web = { [weak self] in self?.attach($0) }
        panels.registerIfAbsent(NavigationPanel.descriptor(state: panel, features: self))
        panels.registerIfAbsent(AnimationPanel.descriptor(state: panel, features: self))
        for command in self.commands() { commands.replace(command) }
        if var release = extensions.descriptor(for: "releaseToLayers") {
            release.validate = { [weak self] in
                guard let window = self?.window() else { return .disabled(Self.noDocument) }
                return window.objectEditing.hasSelection ? .enabled : .disabled(ObjectMenuCommands.noSelection)
            }
            release.run = { [weak self] _ in
                self?.presentReleaseToLayers()
                return nil
            }
            extensions.replace(release)
        }
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.touch() }
        }
    }

    // MARK: Windows

    @discardableResult
    func attach(_ window: DocumentWindowController) -> WindowWeb {
        let key = ObjectIdentifier(window)
        if let existing = windows[key] { return existing.web }
        let web = WindowWeb(window: window)
        web.install()
        let closing = window.window.map { nswindow in
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nswindow, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated { if let window { self?.detach(window) } }
            }
        }
        windows[key] = (window, web, closing)
        let previousSelection = window.onSelectionChange
        window.onSelectionChange = { [weak self] window in
            previousSelection?(window)
            self?.panel.touch()
        }
        panel.touch()
        return web
    }

    func detach(_ window: DocumentWindowController) {
        guard let entry = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
        if let closing = entry.closing { NotificationCenter.default.removeObserver(closing) }
        entry.web.tearDown()
        panel.touch()
    }

    var front: (window: DocumentWindowController, web: WindowWeb)? {
        guard let window = window() else { return nil }
        return (window, attach(window))
    }

    // MARK: Commands

    func commands() -> [Command] {
        let file = StandardCommands.Menu.file
        let hasWindow: @MainActor @Sendable () -> CommandValidation = { [weak self] in self?.window() == nil ? .disabled(Self.noDocument) : .enabled }
        let hasFrames: @MainActor @Sendable () -> CommandValidation = { [weak self] in
            guard let front = self?.front else { return .disabled(Self.noDocument) }
            return front.web.frames.isEmpty ? .disabled(Self.noFrames) : .enabled
        }
        let layer: @MainActor @Sendable () -> CommandValidation = { [weak self] in
            guard let window = self?.window() else { return .disabled(Self.noDocument) }
            return Self.targetLayer(window) == nil ? .disabled(Self.noLayer) : .enabled
        }
        let transport: (CommandID, String, KeyEquivalent?, @escaping @MainActor (WindowWeb) -> Void) -> Command = { id, title, key, body in
            Command(id: id, title: title, key: key, menu: MenuPath(StandardCommands.Menu.window, "Animation", section: StandardCommands.Section.windowArrange + 1),
                    keywords: ["animation", "frame", "preview"], validation: hasFrames,
                    action: .perform { [weak self] in if let web = self?.front?.web { body(web) } })
        }
        return [
            Command(id: ID.publish, title: "Publish as HTML…", menu: MenuPath(file, section: 4), keywords: ["html", "web", "publish", "website"],
                    validation: hasWindow, action: .perform { [weak self] in self?.presentPublish() }),
            Command(id: ID.htmlSetup, title: "HTML Setup…", menu: MenuPath(file, section: 4), keywords: ["html", "web", "settings"],
                    validation: hasWindow, action: .perform { [weak self] in self?.presentSetup() }),
            Command(id: ID.exportAnimatedSVG, title: "Export Animated SVG…", menu: MenuPath(file, section: 4), keywords: ["svg", "animation", "css"],
                    validation: hasFrames, action: .perform { [weak self] in Task { await self?.exportAnimatedSVG() } }),
            transport(ID.play, "Play", KeyEquivalent("return", [.command, .option])) { $0.togglePlay() },
            transport(ID.nextFrame, "Step Forward", nil) { $0.step(1) },
            transport(ID.previousFrame, "Step Backward", nil) { $0.step(-1) },
            transport(ID.firstFrame, "First Frame", KeyEquivalent("home", [.command, .option])) { $0.first() },
            transport(ID.lastFrame, "Last Frame", KeyEquivalent("end", [.command, .option])) { $0.last() },
            Command(id: ID.frameHold, title: "Hold…", contexts: [.layer], keywords: ["animation", "hold", "frame"], validation: layer,
                    action: .perform { [weak self] in self?.presentHold() }),
            Command(id: ID.excludeFromAnimation, title: "Exclude from Animation", contexts: [.layer], keywords: ["animation"],
                    validation: { [weak self] in
                        guard let window = self?.window() else { return .disabled(Self.noDocument) }
                        guard let layer = Self.targetLayer(window) else { return .disabled(Self.noLayer) }
                        return .checked(window.documentHandle.state.props(layer).layer.frame.excluded)
                    },
                    action: .perform { [weak self] in
                        guard let window = self?.window(), let layer = Self.targetLayer(window) else { return }
                        let excluded = window.documentHandle.state.props(layer).layer.frame.excluded
                        window.objectEditing.perform(SetLayerFrame([layer], excluded: !excluded))
                    }),
        ]
    }

    /// The layer the Layers panel's commands act on: the current layer.
    static func targetLayer(_ window: DocumentWindowController) -> OpID? {
        window.objectEditing.activeLayer
    }

    // MARK: Sheets

    @discardableResult
    func present<Content: View>(_ content: Content, identifier: String, title: String, on window: DocumentWindowController?,
                                teardown: (@MainActor () -> Void)? = nil) -> NSWindow {
        dismiss(identifier)
        teardowns[identifier] = teardown
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: content))
        sheet.identifier = NSUserInterfaceItemIdentifier(identifier)
        sheet.title = title
        sheet.isReleasedWhenClosed = false
        sheet.animationBehavior = .none
        sheets[identifier] = sheet
        presentSheet(sheet, window?.window)
        return sheet
    }

    func dismiss(_ identifier: String) {
        teardowns.removeValue(forKey: identifier)?()
        guard let sheet = sheets.removeValue(forKey: identifier) else { return }
        // A sheet on this one (the HTML Setup sheet on the Publish sheet) goes first.
        for (id, other) in sheets where other.sheetParent === sheet { dismiss(id) }
        if let child = sheet.attachedSheet { sheet.endSheet(child) }
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
    }

    /// menu:Extensions[Animate > Release to Layers…].
    @discardableResult
    func presentReleaseToLayers() -> ReleaseToLayersModel? {
        guard let window = window(), window.objectEditing.hasSelection else { return nil }
        let model = ReleaseToLayersModel(window: window, preferences: preferences)
        model.onClose = { [weak self] in self?.dismiss(Self.releaseSheet) }
        present(ReleaseToLayersSheet(model: model), identifier: Self.releaseSheet, title: "Release to Layers", on: window)
        return model
    }

    /// The Layers panel's *Hold…*: frame periods for the layer.
    func presentHold() {
        guard let window = window(), let layer = Self.targetLayer(window) else { return }
        let hold = max(1, Int(window.documentHandle.state.props(layer).layer.frame.hold))
        present(FrameHoldSheet(hold: hold) { [weak self] value in
            self?.dismiss("frame-hold-sheet")
            if let value { window.objectEditing.perform(SetLayerFrame([layer], hold: value)) }
        }, identifier: "frame-hold-sheet", title: "Frame Hold", on: window)
    }

    /// menu:File[Publish as HTML…].
    @discardableResult
    func presentPublish() -> PublishModel? {
        guard let window = window() else { return nil }
        let model = PublishModel(window: window, features: self)
        model.onClose = { [weak self] in self?.dismiss(Self.publishSheet) }
        present(PublishSheet(model: model), identifier: Self.publishSheet, title: "Publish as HTML", on: window, teardown: model.tearDown)
        return model
    }

    /// The HTML Setup sheet.
    @discardableResult
    func presentSetup() -> HTMLSetupModel? {
        guard let window = window() else { return nil }
        let model = HTMLSetupModel(window: window, features: self)
        model.onClose = { [weak self] in self?.dismiss(Self.setupSheet) }
        present(HTMLSetupSheet(model: model), identifier: Self.setupSheet, title: "HTML Setup", on: window, teardown: model.tearDown)
        return model
    }

    // MARK: Scenes

    /// The document as the web exporters read it: every page (or the chosen ones), the animation,
    /// the text-range link rectangles.
    func scene(of window: DocumentWindowController, pages: [Int]? = nil) throws -> ExportScene {
        let document = window.documentHandle
        let exportPages = document.pageList.exportPages
        let request = ExportSnapshot.Request(name: document.title, pages: exportPages, scope: .pages(pages ?? Array(exportPages.indices)),
                                             includePageBoundary: false, pageColor: .white, animation: true)
        var builder = DocumentDisplayListBuilder(canvas: CanvasID("web-\(document.id)"))
        builder.textLayout = TextSceneLayout(engine: document.textEngine)
        let blobs = blobs
        var scene = try ExportSnapshot.capture(document.state, request: request, builder: builder, blob: { blobs.cached($0) }).resolved()
        scene.textLinks = ExportSnapshot.textLinks(document.state, engine: document.textEngine)
        return scene
    }

    /// *Export Animated SVG…*: the document's animation as one SVG in a chosen folder.
    @discardableResult
    func exportAnimatedSVG(to folder: URL? = nil) async -> URL? {
        guard let window = window() else { return nil }
        let destination: URL?
        if let folder { destination = folder } else { destination = await chooseFolder(window.window) }
        guard let destination else { return nil }
        do {
            let scene = try scene(of: window)
            let url = destination.appending(path: "\(window.documentHandle.title).svg")
            let options = AnimatedSVGOptions(autoplay: AnimationInfo(window.documentHandle.state).autoplay)
            _ = try AnimatedSVGExporter().export(scene: scene, options: options, to: ExportDestination(url: url))
            reveal([url])
            return url
        } catch {
            window.statusBar.show(message: "The animated SVG could not be exported: \(error.localizedDescription)")
            return nil
        }
    }
}

/// The Navigation and Animation panels' app-wide state: the front window and a revision.
@MainActor
@Observable
final class WebPanelState {
    private(set) var revision = 0
    @ObservationIgnored var window: @MainActor () -> DocumentWindowController? = { nil }
    @ObservationIgnored var web: @MainActor (DocumentWindowController) -> WindowWeb? = { _ in nil }

    init() {}

    func touch() { revision += 1 }

    var front: (window: DocumentWindowController, web: WindowWeb)? {
        guard let window = window(), let web = web(window) else { return nil }
        return (window, web)
    }
}

/// *Hold…*: how many frame periods the layer's frame lasts.
struct FrameHoldSheet: View {
    @State var hold: Int
    let finish: @MainActor (Int?) -> Void

    static func confirm(_ hold: Int, _ finish: @escaping @MainActor (Int?) -> Void) -> () -> Void { { finish(min(max(hold, 1), 10_000)) } }
    static func cancel(_ finish: @escaping @MainActor (Int?) -> Void) -> () -> Void { { finish(nil) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper("Hold for \(hold) \(hold == 1 ? "frame" : "frames")", value: $hold, in: 1...10_000)
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancel(finish)).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.confirm(hold, finish)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

extension AppDelegate {
    /// The web panels, sheets and commands.
    func installWeb() {
        let documents = documents!
        web.blobs = imports.blobs
        WebSections.blobs = imports.blobs
        web.install(commands: commands, panels: panels, extensions: toolbars.extensions) { documents.activeWindowController }
    }
}
