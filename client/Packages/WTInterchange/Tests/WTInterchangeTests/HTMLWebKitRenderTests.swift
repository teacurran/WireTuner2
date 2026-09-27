// WEB-008, the render half: each corpus document is published under every layout × page mode ×
// vector format, written to a folder, loaded from disk into a headless `WKWebView` (no window, no
// network), and every page's `<section>` is snapshotted and compared with the app's own render of
// that page -- the Core Graphics renderer's, placed images drawn in -- at the snapshot's pixel scale,
// within the anti-aliasing tolerance the other export comparisons use.  macOS only: the packages' iOS
// build compiles none of it.

#if canImport(WebKit) && os(macOS)
import AppKit
import CoreGraphics
import Foundation
import Testing
import WebKit
import WTGeometry
@testable import WTInterchange
import WTRender

/// A headless web view that loads a file and snapshots parts of it.
@MainActor
final class HeadlessPage: NSObject, WKNavigationDelegate {
    let view: WKWebView
    private var loading: CheckedContinuation<Void, any Error>?

    init(width: Double, height: Double) {
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        super.init()
        view.navigationDelegate = self
    }

    func load(_ url: URL, root: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            view.loadFileURL(url, allowingReadAccessTo: root)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finish(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finish(error) }
    }

    private func finish(_ error: (any Error)?) {
        guard let loading else { return }
        self.loading = nil
        if let error { loading.resume(throwing: error) } else { loading.resume() }
    }

    /// Each `section.page`'s rectangle in the view, in document order.
    func sections() async throws -> [CGRect] {
        let script = "JSON.stringify([...document.querySelectorAll('section.page')].map(s => { const r = s.getBoundingClientRect(); return [r.left, r.top, r.width, r.height] }))"
        let json = try await view.evaluateJavaScript(script) as? String ?? "[]"
        let values = try JSONDecoder().decode([[Double]].self, from: Data(json.utf8))
        return values.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
    }

    /// `rect` of the view as pixels, once two snapshots in a row agree (embedded objects, images
    /// and fonts load after the navigation finishes).
    func snapshot(_ rect: CGRect) async throws -> CGImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.afterScreenUpdates = true
        var previous: Data?
        var image: CGImage?
        for _ in 0..<20 {
            let taken = try await view.takeSnapshot(configuration: configuration)
            guard let cg = taken.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ExportError.nothingToExport }
            let bytes = Data(Corpus.pixels(cg).bytes)
            image = cg
            if bytes == previous { break }
            previous = bytes
            try await Task.sleep(for: .milliseconds(50))
        }
        return image!
    }
}

@Suite(.serialized) struct HTMLWebKitRenderTests {
    /// Pixels differing by more than this in some channel count as different.
    static let tolerance = 40
    /// The share of such pixels allowed per page: anti-aliasing along every edge, JPEG-encoded
    /// sampled paints, and the raster effects SVG filters draw a little differently.
    static func allowance(_ document: String, vector: HTMLVectorFormat) -> Double {
        switch document {
        case "effects", "sampled": 0.06
        // Half-pixel page edges: every edge lands between device pixels.
        case "fractional": 0.035
        case "text", "words", "three pages": 0.03
        default: 0.02
        }
    }

    /// `image` cropped to `width` × `height` from its top-left.
    static func crop(_ image: CGImage, _ width: Int, _ height: Int) -> CGImage {
        guard image.width != width || image.height != height else { return image }
        return image.cropping(to: CGRect(x: 0, y: 0, width: width, height: height))!
    }

    /// References by document, page index and scale: the eight combinations share them.
    @MainActor static var references: [String: CGImage] = [:]

    @MainActor static func cachedReference(_ document: HTMLCorpusDocument, page index: Int, scale: Double) throws -> CGImage {
        let key = "\(document.name)/\(index)/\(scale)"
        if let image = references[key] { return image }
        let image = try reference(document.scene.pages[index], scene: document.scene, scale: scale)
        references[key] = image
        return image
    }

    /// The app's render of `page` at `scale` over white: the canvas's Core Graphics renderer
    /// (`Corpus.reference`), with the placed images the package cannot decode drawn in.
    static func reference(_ page: ExportPage, scene: ExportScene, scale: Double) throws -> CGImage {
        withPlacedImages(Corpus.reference(page, scale: scale), page: page, scene: scene, scale: scale)
    }

    /// `image` with the page's top-level placed images drawn over their placeholders from the
    /// scene's assets: without an `ImageStore` the renderer draws every placed image as its
    /// placeholder, which is not what the page looks like in the app.
    static func withPlacedImages(_ image: CGImage, page: ExportPage, scene: ExportScene, scale: Double) -> CGImage {
        let placed = page.displayList.items.compactMap { item -> ImageItem? in
            if case .image(let placed) = item, scene.assets[placed.assetID] != nil { return placed }
            return nil
        }
        guard !placed.isEmpty else { return image }
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Top-left page coordinates in points.
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -page.bounds.minX, y: -page.bounds.minY)
        context.interpolationQuality = .high
        for item in placed {
            let t = item.transform
            context.saveGState()
            context.concatenate(CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty))
            // The bitmap's first row at the rectangle's top.
            context.translateBy(x: item.rect.minX, y: item.rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(scene.assets[item.assetID]!.image, in: CGRect(x: 0, y: 0, width: item.rect.width, height: item.rect.height))
            context.restoreGState()
        }
        return context.makeImage()!
    }

    @MainActor @Test(arguments: HTMLCorpus.combinations)
    func headlessWebKitMatchesTheAppsRender(layout: HTMLLayout, mode: HTMLPageMode, vector: HTMLVectorFormat) async throws {
        let settings = HTMLPublishSettings(layout: layout, pageMode: mode, vectorFormat: vector, scale: 2, background: .white)
        let clock = ContinuousClock()
        let started = clock.now
        var publishing = Duration.zero, snapshotting = Duration.zero
        var worst: [(String, Double)] = []
        let page = HeadlessPage(width: 200, height: 200)
        for document in HTMLCorpus.documents {
            let publishStart = clock.now
            let bundle = try HTMLPublisher(settings: settings).publish(document.scene)
            publishing += clock.now - publishStart
            let folder = Corpus.directory().appendingPathComponent("webkit-\(UUID().uuidString.prefix(8))")
            try bundle.write(to: folder)
            let pages = document.scene.pages
            let width = pages.map(\.bounds.width).max() ?? 100
            let height = pages.reduce(24) { $0 + $1.bounds.height + 24 } + 60
            let files = mode == .stacked ? ["index.html"] : pages.indices.map { $0 == 0 ? "index.html" : "page-\(pages[$0].number ?? $0 + 1).html" }
            var index = 0
            page.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            for file in files {
                try await page.load(folder.appendingPathComponent(file), root: folder)
                let rects = try await page.sections()
                #expect(rects.count == (mode == .stacked ? pages.count : 1), "\(document.name) \(file)")
                for rect in rects where index < pages.count {
                    let label = "\(document.name) page \(index + 1) \(layout) \(mode) \(vector)"
                    let snapshotStart = clock.now
                    let shot = try await page.snapshot(rect)
                    snapshotting += clock.now - snapshotStart
                    let scale = Double(shot.width) / rect.width
                    let reference = try Self.cachedReference(document, page: index, scale: scale)
                    let (w, h) = (min(shot.width, reference.width), min(shot.height, reference.height))
                    #expect(abs(shot.width - reference.width) <= 1 && abs(shot.height - reference.height) <= 1, "\(label): \(shot.width)×\(shot.height) vs \(reference.width)×\(reference.height)")
                    let difference = Corpus.difference(Self.crop(reference, w, h), Self.crop(shot, w, h), tolerance: Self.tolerance)
                    worst.append((label, difference))
                    if difference > Self.allowance(document.name, vector: vector) {
                        Corpus.dump(shot, "webkit-\(document.name)-\(index + 1)-\(layout)-\(mode)-\(vector)")
                        Corpus.dump(reference, "webkit-\(document.name)-\(index + 1)-reference")
                    }
                    if vector == .png, document.scene.assets.isEmpty == false {
                        // PNG pages come from the bitmap exporter, which draws placed images as
                        // their placeholders (no `ImageStore` in the package's export path).
                        withKnownIssue("PNG pages draw placed images as placeholders") {
                            #expect(difference <= Self.allowance(document.name, vector: vector), "\(label): \(difference)")
                        }
                    } else {
                        #expect(difference <= Self.allowance(document.name, vector: vector), "\(label): \(difference)")
                    }
                    index += 1
                }
            }
            #expect(index == pages.count, "\(document.name): \(index) of \(pages.count) pages compared")
            try? FileManager.default.removeItem(at: folder)
        }
        let summary = worst.sorted { $0.1 > $1.1 }.prefix(5).map { "\($0.0): \(String(format: "%.4f", $0.1))" }
        print("WEBKIT \(layout) \(mode) \(vector) in \(clock.now - started) (publishing \(publishing), snapshots \(snapshotting)) worst: \(summary)")
    }
}
#endif
