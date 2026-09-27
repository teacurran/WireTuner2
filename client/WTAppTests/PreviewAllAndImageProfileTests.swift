import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
@testable import WireTuner

/// WEB-029: Preview All Pages in Browser and the preview's warnings.
@Suite(.serialized) @MainActor struct PreviewAllPagesTests {
    final class StubExporter: BrowserPreviewExporter {
        private(set) var exported: [(page: Int, all: Bool)] = []
        var warnings: [String] = []

        func exportPreview(of document: DocumentHandle, pageIndex: Int, into directory: URL) throws -> URL {
            try exportPreview(of: document, pageIndex: pageIndex, allPages: false, into: directory)
        }

        func exportPreview(of document: DocumentHandle, pageIndex: Int, allPages: Bool, into directory: URL) throws -> URL {
            exported.append((pageIndex, allPages))
            let file = directory.appending(path: "index.html")
            try Data("<html></html>".utf8).write(to: file)
            return file
        }
    }

    /// An exporter that implements only the one-page export: all pages falls back to it.
    final class OnePageExporter: BrowserPreviewExporter {
        private(set) var count = 0
        func exportPreview(of document: DocumentHandle, pageIndex: Int, into directory: URL) throws -> URL {
            count += 1
            return directory
        }
    }

    @Test func previewAllPagesExportsEveryPageAndListsTheWarnings() throws {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .memory(id: "all", title: "All"), environment: environment.document)
        defer { controller.close() }
        let exporter = StubExporter()
        let preview = BrowserPreview(exporter: exporter, root: TestEnvironment.temporaryDirectory())
        preview.open = { _, _ in }
        ViewCommands.install(into: environment.commands, target: { [weak controller] in controller }, hooks: ViewCommands.Hooks(browserPreview: preview))
        let all = StandardCommands.ID.previewAllInBrowser
        #expect(environment.commands.command(all)?.defaultKey == KeyEquivalent("return", [.command, .shift]))
        #expect(environment.commands.command(all)?.title == "Preview All Pages in Browser")
        #expect(environment.commands.validate(all) == .enabled)
        // Nothing to warn about: the status bar is left alone.
        controller.statusBar.show(message: "")
        #expect(environment.commands.perform(all))
        #expect(exporter.exported.last?.all == true)
        #expect(controller.statusBar.message.stringValue.isEmpty)
        exporter.warnings = ["Page 1: a link is not valid.", "“photo.png” is not downloaded yet; the preview shows its placeholder."]
        #expect(environment.commands.perform(StandardCommands.ID.previewInBrowser))
        #expect(exporter.exported.last?.all == false)
        #expect(controller.statusBar.message.stringValue == "Preview: " + exporter.warnings.joined(separator: "  "))
        // An exporter with only the one-page export serves both commands.
        let plain = OnePageExporter()
        #expect(plain.warnings.isEmpty)
        _ = try plain.exportPreview(of: controller.documentHandle, pageIndex: 0, allPages: true, into: TestEnvironment.temporaryDirectory())
        #expect(plain.count == 1)
    }

    @Test func webPreviewAllPagesPublishesEveryPage() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let document = setup.document
        await document.addRectangles([Rect(x: setup.page.rect.minX + 10, y: setup.page.rect.minY + 10, width: 50, height: 50)])
        await document.addPage().value
        await document.settle()
        let exporter = WebPreviewExporter()
        #expect(!WebPreviewExporter.hasInteractions(document))
        let folder = TestStores.directory()
        let one = try exporter.exportPreview(of: document, pageIndex: 1, into: folder.appending(path: "one"))
        #expect(one.lastPathComponent == "index.html")
        let all = try exporter.exportPreview(of: document, pageIndex: 1, allPages: true, into: folder.appending(path: "all"))
        // The current page's file, or the one file the setting stacks every page in.
        #expect(["page-2.html", "index.html"].contains(all.lastPathComponent) && FileManager.default.fileExists(atPath: all.path))
        #expect(exporter.warnings.allSatisfy { !$0.isEmpty })
    }
}

/// CMS-012's app half: the *Embedded image profiles* preference decides, and *Ask* asks once per
/// import.
@Suite(.serialized) @MainActor struct EmbeddedImageProfileTests {
    static func adobeJPEG(in world: ImportWorld, _ name: String) throws -> URL {
        try image(in: world, name, space: CGColorSpace(name: CGColorSpace.adobeRGB1998)!, type: .jpeg)
    }

    /// An 8 × 8 image in `space` written as `type` (a device-RGB TIFF carries no profile).
    static func image(in world: ImportWorld, _ name: String, space: CGColorSpace, type: UTType) throws -> URL {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [0.2, 0.7, 0.3, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return world.files.write(name, data as Data)
    }

    @Test func eachPreferenceValue() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let files = [try Self.adobeJPEG(in: world, "a.jpg"), try Self.adobeJPEG(in: world, "b.jpg")]
        var asked: [String] = []
        world.imports.askEmbeddedProfile = { name, _ in
            asked.append(name)
            return .ignore
        }
        for (value, used) in [("use", true), ("ignore", false), ("ask", false)] {
            _ = world.environment.preferences.set(value, for: PreferenceCatalog.Import.embeddedProfiles)
            let outcome = await world.imports.place(files, on: world.window, at: Point(x: 0, y: 0))
            #expect(outcome.placed.count == 2 && outcome.failures.isEmpty)
            for node in outcome.placed {
                let color = world.state.props(node).image.color
                #expect(color.embeddedProfile.name.contains("Adobe RGB") && color.useEmbedded == used, "\(value)")
            }
        }
        #expect(asked.count == 1, "one answer covers the import")
        #expect(asked.first?.contains("Adobe RGB") == true)
        // A file without a profile never asks.
        let plain = try Self.image(in: world, "plain.tiff", space: CGColorSpaceCreateDeviceRGB(), type: .tiff)
        _ = await world.imports.place([plain], on: world.window, at: nil)
        #expect(asked.count == 1)
        #expect(ImportController.embeddedProfileName(in: ImportedScene(kind: .vector, name: "g", bounds: Rect(x: 0, y: 0, width: 1, height: 1),
                                                                         nodes: [.group(ImportedGroup(children: []))])) == nil)
    }
}
