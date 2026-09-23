import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit
import WTGeometry
import WTInterchange
import WTRender

/// An SVG animation's poster frame (svg-animation.adoc, "Client"; WEB-025): a PNG of the file at
/// time 0, at twice the placed size capped at 4,096 pixels, drawn by an offscreen `WKWebView`
/// with the animations paused.  The page's own scripts never run (only the app's pausing script
/// does).  When WebKit does not deliver within the timeout, the poster is drawn instead from the
/// file converted to static objects (its first frame as the SVG importer reads it), so an
/// animation is never placed without one.
@MainActor
final class PosterRenderer {
    /// The longest edge a poster is rendered at.
    static let maximumPixels = 4_096.0
    /// How long WebKit gets before the static rendering is used.
    var timeout: Duration = .seconds(3)
    /// Draws through WebKit; nil for an SVG it could not draw.  Replaceable in tests.
    var web: @MainActor (Data, Size) async -> Data? = { data, size in await WebPosterSnapshot().png(svg: data, size: size) }

    /// The poster of `svg`, whose view box is `bounds`: a PNG blob, or nil when neither WebKit nor
    /// the static rendering can draw it.
    func poster(svg: Data, bounds: Rect) async -> ImportedBlob? {
        let size = Self.pixelSize(bounds)
        let web = web
        let timeout = timeout
        // Whichever comes first: WebKit's snapshot or the timeout (a load that never finishes is
        // abandoned, not awaited).
        let drawn: Data? = await withCheckedContinuation { continuation in
            let first = FirstResult(continuation)
            Task { @MainActor in first.resume(await web(svg, size)) }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                first.resume(nil)
            }
        }
        guard let png = drawn ?? Self.staticPNG(svg: svg, size: size) else { return nil }
        return ImportedBlob(data: png, uti: UTType.png.identifier)
    }

    /// Twice the view box, the long edge at most 4,096 pixels, at least 1 × 1.
    static func pixelSize(_ bounds: Rect) -> Size {
        let doubled = Size(width: max(bounds.width, 1) * 2, height: max(bounds.height, 1) * 2)
        let scale = min(1, maximumPixels / max(doubled.width, doubled.height))
        return Size(width: max((doubled.width * scale).rounded(), 1), height: max((doubled.height * scale).rounded(), 1))
    }

    /// The file converted to static objects and drawn by the reference renderer.
    static func staticPNG(svg: Data, size: Size) -> Data? {
        let options = SVGImportOptions(animation: .convert).values
        guard let scene = try? ImportRegistry.standard.convert(svg, name: "poster.svg", options: options), scene.bounds.width > 0,
              scene.bounds.height > 0, let page = scene.exportScene().pages.first else { return nil }
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CoreGraphicsRenderer.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: size.width / page.bounds.width, y: size.height / page.bounds.height)
        let viewport = Viewport(scrollOrigin: Point(x: page.bounds.minX, y: page.bounds.minY), size: Size(width: page.bounds.width, height: page.bounds.height))
        CoreGraphicsRenderer(background: nil).render(page.displayList, viewport: viewport, into: context)
        return context.makeImage().flatMap(png)
    }

    /// `image` as PNG data.
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        // ImageIO always has a PNG destination.
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

/// Resumes a continuation with the first result it is given and ignores the rest.
@MainActor
final class FirstResult<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// One offscreen `WKWebView` snapshot of an SVG with its animations paused at time 0.
@MainActor
final class WebPosterSnapshot: NSObject, WKNavigationDelegate {
    /// Pauses CSS animations and transitions (Web Animations) and SMIL at time 0.
    static let pause = """
        document.getAnimations().forEach(a => { a.pause(); a.currentTime = 0; });
        const root = document.documentElement;
        if (root.pauseAnimations) { root.pauseAnimations(); root.setCurrentTime(0); }
        true
        """

    private var finished: CheckedContinuation<Bool, Never>?

    /// The PNG of `svg` drawn at `size` pixels, or nil when WebKit could not load it.
    func png(svg: Data, size: Size) async -> Data? {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2), configuration: configuration)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        let loaded = await withCheckedContinuation { continuation in
            finished = continuation
            view.load(svg, mimeType: "image/svg+xml", characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
        }
        guard loaded, (try? await view.evaluateJavaScript(Self.pause)) != nil else { return nil }
        let snapshot = WKSnapshotConfiguration()
        snapshot.snapshotWidth = NSNumber(value: size.width / 2)
        guard let image = try? await view.takeSnapshot(configuration: snapshot),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return PosterRenderer.png(cgImage)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resume(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        resume(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        resume(false)
    }

    private func resume(_ loaded: Bool) {
        finished?.resume(returning: loaded)
        finished = nil
    }
}
