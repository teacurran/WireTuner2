import AppKit
import SwiftUI
import WebKit
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender

/// What the SVG Animation section reads and writes outside the document: the blob cache and the
/// frame renderer (set up by `WebFeatures.install`).
@MainActor
enum WebSections {
    /// The blobs of the document's assets.
    static var blobs = BlobPlacement()
    /// A PNG of `svg` at `timeMs`, `size` pixels (an offscreen `WKWebView` in the app).
    static var renderFrame: @MainActor (Data, Size, UInt64) async -> Data? = { svg, size, time in await WebFrameSnapshot().png(svg: svg, size: size, timeMs: time) }
    /// Frames already rendered this session, by asset and time (the snapshot strip's cache).
    static var frames: [String: Data] = [:]
    /// Saves a copy of the stored file (the save panel in the app).
    static var chooseDestination: @MainActor (String, NSWindow?) async -> URL? = { name, window in
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        return await ModalUI.url(panel, on: window)
    }
    static var reveal: @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }

    static func register(into registry: InspectorRegistry) {
        registry.register(InspectorSection(id: "svgAnimation", order: 74, kinds: nil) { panel in
            SvgAnimationSectionModel(panel).map { AnyView(SvgAnimationSectionView(model: $0)) }
        })
    }
}

/// The Object panel's *SVG Animation* section (WEB-027; svg-animation.adoc, "SVG animation
/// attributes in the Object panel"): size and scale against the file's natural size, the poster
/// frame scrubber (one change on release), *On the web*, the duration, the *Scripts* flag and the
/// file, with btn:[Reveal] and btn:[Save a Copy…].
@MainActor
struct SvgAnimationSectionModel {
    let panel: ObjectPanelModel
    let info: SvgAnimationInfo

    init?(_ panel: ObjectPanelModel) {
        let state = panel.document.state
        let nodes = panel.selection.ids.map(\.opID)
        guard nodes.count == 1, state.store.kind(nodes[0]) == SvgAnimationFields.kind, let info = SvgAnimationInfo(nodes[0], in: state) else { return nil }
        self.panel = panel
        self.info = info
    }

    var state: EngineState { panel.document.state }
    var file: AssetLink? { info.asset.flatMap { AssetLink.read($0, in: state) } }

    /// Width and height on the pasteboard (the natural size through the transform).
    var size: Size {
        let bounds = info.bounds.applying(info.transform)
        return Size(width: bounds.width, height: bounds.height)
    }

    /// *Scale X* and *Scale Y*: the size as a share of the natural size, in percent.
    var scale: (x: Double, y: Double) {
        let natural = info.naturalSize
        // The read-time rule gives every animation a non-zero natural size.
        return (size.width / natural.width * 100, size.height / natural.height * 100)
    }

    /// "2.50 s", or *Indefinite* for a file with no end.
    var duration: String { info.durationMs == 0 ? "Indefinite" : Self.seconds(info.durationMs) }

    static func seconds(_ ms: UInt64) -> String { String(format: "%.2f s", Double(ms) / 1000) }

    var scripts: String { info.kinds.script ? "Uses script — stripped on publish unless allowed" : "None" }

    var fileLine: String {
        let name = file?.fileName ?? "Missing file"
        return "\(name), \(Int(info.naturalSize.width)) × \(Int(info.naturalSize.height))"
    }

    /// The scrubber's range in milliseconds (a looping file with no end scrubs its first 10 s).
    var scrubRange: ClosedRange<Double> { 0...Double(info.durationMs == 0 ? 10_000 : max(info.durationMs, 1)) }

    // MARK: Writes

    @discardableResult
    func setWeb(autoplay: Bool? = nil, loop: SvgAnimationLoop? = nil, playOnHover: Bool? = nil) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        panel.perform(SetSvgAnimationWeb([info.node], autoplay: autoplay, loop: loop, playOnHover: playOnHover))
    }

    /// The scrubber released at `timeMs`: that frame is rendered (or taken from the strip's
    /// cache), stored and made the poster in one change.
    @discardableResult
    func setPoster(at timeMs: UInt64) async -> Wiretuner_Doc_V1_Change? {
        guard let file, let svg = WebSections.blobs.cached(file.sha256) else { return nil }
        let key = "\(file.id):\(timeMs)"
        let png: Data
        if let cached = WebSections.frames[key] {
            png = cached
        } else {
            guard let rendered = await WebSections.renderFrame(svg, PosterRenderer.pixelSize(info.bounds), timeMs) else { return nil }
            WebSections.frames[key] = rendered
            png = rendered
        }
        let blob = ImportedBlob(data: png, uti: "public.png")
        try? await WebSections.blobs.store([blob], for: panel.document)
        return await panel.perform(SetSvgAnimationPosterFrame(info.node, timeMs: timeMs, png: blob))?.value
    }

    /// btn:[Save a Copy…]: the stored file written out.
    @discardableResult
    func saveCopy(window: NSWindow?) async -> URL? {
        guard let file, let data = WebSections.blobs.cached(file.sha256),
              let url = await WebSections.chooseDestination(file.fileName, window) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// btn:[Reveal]: the original file, when this Mac still has it.
    var originalURL: URL? {
        guard let file, !file.path.isEmpty, FileManager.default.fileExists(atPath: file.path) else { return nil }
        return URL(filePath: file.path)
    }

    func reveal() {
        if let originalURL { WebSections.reveal([originalURL]) }
    }
}

struct SvgAnimationSectionView: View {
    let model: SvgAnimationSectionModel
    @State private var scrub: Double?

    static func autoplay(_ model: SvgAnimationSectionModel) -> Binding<Bool> {
        Binding(get: { model.info.web.autoplay }, set: { model.setWeb(autoplay: $0) })
    }

    static func loop(_ model: SvgAnimationSectionModel) -> Binding<SvgAnimationLoop> {
        Binding(get: { model.info.web.loop }, set: { model.setWeb(loop: $0) })
    }

    static func hover(_ model: SvgAnimationSectionModel) -> Binding<Bool> {
        Binding(get: { model.info.web.playOnHover }, set: { model.setWeb(playOnHover: $0) })
    }

    /// The scrubber released: the frame is written.
    static func released(_ model: SvgAnimationSectionModel, _ value: Double) -> () -> Void {
        { Task { await model.setPoster(at: UInt64(max(value, 0).rounded())) } }
    }

    static func saveCopy(_ model: SvgAnimationSectionModel) -> () -> Void { { Task { await model.saveCopy(window: NSApp.keyWindow) } } }
    static func reveal(_ model: SvgAnimationSectionModel) -> () -> Void { { model.reveal() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SVG Animation").font(.headline)
            Text(String(format: "W %.1f  H %.1f pt   Scale %.0f%% × %.0f%%", model.size.width, model.size.height, model.scale.x, model.scale.y))
                .font(.caption).monospacedDigit()
            HStack {
                Text("Poster frame")
                Slider(value: Binding(get: { scrub ?? Double(model.info.posterTimeMs) }, set: { scrub = $0 }), in: model.scrubRange) { editing in
                    if !editing, let value = scrub {
                        Self.released(model, value)()
                        scrub = nil
                    }
                }
                .accessibilityIdentifier("svgAnimation.poster")
                Text(SvgAnimationSectionModel.seconds(UInt64(scrub ?? Double(model.info.posterTimeMs)))).font(.caption).monospacedDigit()
            }
            Text("On the web").font(.subheadline)
            Toggle("Play automatically", isOn: Self.autoplay(model))
            Picker("Loop", selection: Self.loop(model)) {
                Text("As the file says").tag(SvgAnimationLoop.asFile)
                Text("Loop").tag(SvgAnimationLoop.loop)
                Text("Play once").tag(SvgAnimationLoop.once)
            }
            Toggle("Play on hover", isOn: Self.hover(model))
            LabeledContent("Duration", value: model.duration)
            LabeledContent("Scripts", value: model.scripts)
            LabeledContent("File", value: model.fileLine)
            HStack {
                Button("Reveal", action: Self.reveal(model)).disabled(model.originalURL == nil)
                Button("Save a Copy…", action: Self.saveCopy(model)).disabled(model.file == nil)
            }
            HStack {
                Button("Replace…", action: SvgAnimationFileActions.replacing(model)).accessibilityIdentifier("svgAnimation.replace")
                Button("Edit With…", action: SvgAnimationFileActions.editing(model)).disabled(model.file == nil).accessibilityIdentifier("svgAnimation.editWith")
            }
        }
    }
}

/// One offscreen `WKWebView` snapshot of an SVG with its animations paused at a time.
@MainActor
final class WebFrameSnapshot: NSObject, WKNavigationDelegate {
    /// Pauses CSS animations and transitions and SMIL at `ms` milliseconds.
    static func seek(_ ms: UInt64) -> String {
        """
        document.getAnimations().forEach(a => { a.pause(); a.currentTime = \(ms); });
        const root = document.documentElement;
        if (root.pauseAnimations) { root.pauseAnimations(); root.setCurrentTime(\(Double(ms) / 1000)); }
        true
        """
    }

    private var finished: CheckedContinuation<Bool, Never>?

    func png(svg: Data, size: Size, timeMs: UInt64) async -> Data? {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2), configuration: configuration)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        let loaded = await withCheckedContinuation { continuation in
            finished = continuation
            view.load(svg, mimeType: "image/svg+xml", characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
        }
        guard loaded, (try? await view.evaluateJavaScript(Self.seek(timeMs))) != nil else { return nil }
        let snapshot = WKSnapshotConfiguration()
        snapshot.snapshotWidth = NSNumber(value: size.width / 2)
        guard let image = try? await view.takeSnapshot(configuration: snapshot),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return PosterRenderer.png(cgImage)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { resume(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { resume(false) }

    private func resume(_ loaded: Bool) {
        finished?.resume(returning: loaded)
        finished = nil
    }
}
