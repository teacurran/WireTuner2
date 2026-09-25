import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTInterchange
import WTModel
import WTProto

/// The SVG Animation section's btn:[Replace…] and btn:[Edit With…] (svg-animation.adoc, "SVG
/// animation attributes in the Object panel"; WEB-027): another animated SVG -- chosen in an open
/// panel, or saved by the external editor -- takes the animation's place with its position, size
/// and web settings kept (`ReplaceSvgAnimationFile`), its poster rendered as an import renders it.
@MainActor
enum SvgAnimationFileActions {
    static let notAnimated = "The file is not an animated SVG"

    /// *Replace…*'s open panel; replaceable in tests.
    static var chooseFile: @MainActor () async -> URL? = {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg]
        panel.message = "Choose an animated SVG to replace this one"
        return await panel.begin() == .OK ? panel.url : nil
    }

    /// The import's conversion and blob storage (the app's `ImportController`).
    static var convert: @MainActor (URL) async throws -> ImportedScene = { _ in throw CocoaError(.fileReadUnsupportedScheme) }
    static var storeBlobs: @MainActor (ImportedScene, DocumentHandle) async throws -> ImportedPoster? = { _, _ in nil }
    /// The edit sessions running (until the app quits; the next launch removes their files).
    private(set) static var sessions: [SvgAnimationEditSession] = []

    /// Replaces `node`'s file with the animated SVG at `url`; nil when it is not one.
    @discardableResult
    static func replace(_ node: OpID, with url: URL, in document: DocumentHandle) async -> Wiretuner_Doc_V1_Change? {
        guard let scene = try? await convert(url), case .placed(let placed)? = scene.nodes.first, case .svgAnimation = placed.kind else { return nil }
        let poster = try? await storeBlobs(scene, document)
        return await document.perform(ReplaceSvgAnimationFile(node, file: placed, poster: poster ?? nil)).value
    }

    /// btn:[Replace…].
    @discardableResult
    static func replace(_ model: SvgAnimationSectionModel) async -> Wiretuner_Doc_V1_Change? {
        guard let url = await chooseFile() else { return nil }
        return await replace(model.info.node, with: url, in: model.panel.document)
    }

    /// btn:[Edit With…]: the stored file in the system's SVG editor, each save replacing it.
    @discardableResult
    static func editWith(_ model: SvgAnimationSectionModel, editing: ExternalEditing = .shared) -> SvgAnimationEditSession? {
        guard let file = model.file, let data = WebSections.blobs.cached(file.sha256), let app = editing.systemDefault(.svg) else { return nil }
        let appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        if editing.preferences?[PreferenceCatalog.Object.confirmExternalEditor] ?? true, !editing.confirm(appName) { return nil }
        let url = editing.directory().appending(path: model.panel.document.id).appending(path: "\(model.info.node)-animation.svg")
        let session = SvgAnimationEditSession(document: model.panel.document, node: model.info.node, file: url, original: model.info)
        do { try session.start(data: data) } catch { return nil }
        sessions.append(session)
        editing.open(url, app)
        return session
    }

    static func replacing(_ model: SvgAnimationSectionModel) -> () -> Void { { Task { await replace(model) } } }
    static func editing(_ model: SvgAnimationSectionModel) -> () -> Void { { editWith(model) } }
}

/// One SVG animation being edited in another application: saves (settled) replace the file.
@MainActor
final class SvgAnimationEditSession {
    let document: DocumentHandle
    let node: OpID
    let file: URL
    let original: SvgAnimationInfo
    var debounce: Duration = .milliseconds(300)
    private(set) var replacements = 0
    private var lastData: Data?
    private var pending: Task<Void, Never>?
    private var watch: FileWatch?

    init(document: DocumentHandle, node: OpID, file: URL, original: SvgAnimationInfo) {
        self.document = document
        self.node = node
        self.file = file
        self.original = original
    }

    func start(data: Data) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        lastData = data
        let watch = FileWatch(url: file) { [weak self] in
            Task { @MainActor in self?.fileDidChange() }
        }
        watch.start()
        self.watch = watch
    }

    func fileDidChange() {
        pending?.cancel()
        let debounce = debounce
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    @discardableResult
    func reload() async -> Bool {
        guard let data = try? Data(contentsOf: file), data != lastData else { return false }
        lastData = data
        guard await SvgAnimationFileActions.replace(node, with: file, in: document) != nil else { return false }
        replacements += 1
        return true
    }

    /// Done: the file goes.
    func done() {
        pending?.cancel()
        watch?.stop()
        watch = nil
        try? FileManager.default.removeItem(at: file)
    }
}
