import AppKit
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
@testable import WireTuner

/// IMG-019: the Edit With… round trip with a scripted editor (the test rewrites the file).
@Suite(.serialized) @MainActor struct ExternalEditTests {
    static func png(width: Int, height: Int, gray: CGFloat) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @MainActor
    final class World {
        let setup = SetupWindow()
        let editing = ExternalEditing()
        let folder = TestEnvironment.temporaryDirectory()
        var opened: [(URL, URL)] = []
        var stored: [ImportedBlob] = []
        var image: OpID = .zero
        let original = ExternalEditTests.png(width: 40, height: 20, gray: 0.2)

        init() async throws {
            let decoded = try ImageImporter().decode(original, name: "photo.png")
            let place = PlaceImage(EditedImagePixels.source(decoded.pixels), name: "photo.png", dpiX: 72, dpiY: 72)
            image = try #require(await setup.document.perform(place).value?.createdObjects.first)
            await setup.document.settle()
            let window = setup.window, original = original, hash = decoded.pixels.blob.sha256
            editing.window = { [weak window] in window }
            editing.cached = { $0 == hash ? original : nil }
            editing.store = { [unowned self] blob, _ in self.stored.append(blob) }
            editing.open = { [unowned self] file, app in self.opened.append((file, app)) }
            editing.editors = { _ in [URL(fileURLWithPath: "/Applications/Preview.app"), URL(fileURLWithPath: "/Applications/Other.app")] }
            editing.systemDefault = { _ in URL(fileURLWithPath: "/Applications/Preview.app") }
            editing.confirm = { _ in true }
            let folder = folder
            editing.directory = { folder }
            window.selection.model.set(Selection([SelectionID(image)]))
        }

        var props: Wiretuner_Doc_V1_ImageProps { setup.document.state.props(image).image }

        func waitFor(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        }

        func close() {
            editing.finishAll()
            try? FileManager.default.removeItem(at: folder)
            setup.close()
        }
    }

    @Test func eachSaveReplacesThePixelsAndCancelRestoresTheOriginal() async throws {
        let w = try await World()
        defer { w.close() }
        let before = ImageNodes.naturalRect(w.props)
        let session = try #require(w.editing.editFromPanel())
        session.debounce = .milliseconds(20)
        #expect(w.opened.count == 1 && w.opened[0].1.lastPathComponent == "Preview.app" && session.appName == "Preview")
        #expect(FileManager.default.fileExists(atPath: session.file.path) && w.editing.sessions.count == 1)
        #expect(w.editing.edit(w.image, in: w.setup.window) === session, "one session per image")
        // The editor saves a wider image: within a second the pixels change, the width stays.
        try Self.png(width: 80, height: 80, gray: 0.8).write(to: session.file)
        try await w.waitFor { session.replacements == 1 }
        await w.setup.document.settle()
        #expect(session.replacements == 1 && w.props.pixels.pixelWidth == 80 && w.stored.count == 1)
        let after = ImageNodes.naturalRect(w.props)
        #expect(abs(after.width - before.width) < 1e-6 && abs(after.height - before.width) < 1e-6)
        // An editor that saves by atomic rename is seen too.
        let replacement = session.file.deletingLastPathComponent().appending(path: "incoming.png")
        try Self.png(width: 60, height: 30, gray: 0.5).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(session.file, withItemAt: replacement)
        try await w.waitFor { session.replacements == 2 }
        #expect(session.replacements == 2)
        // A save that changes nothing replaces nothing; an unreadable file neither.
        #expect(await session.reload() == false)
        try Data("not an image".utf8).write(to: session.file)
        #expect(await session.reload() == false)
        // Cancel: the original hash, the file gone.
        _ = await w.editing.cancel(session).value
        await w.setup.document.settle()
        #expect(w.props.pixels.blobSha256 == session.original.blobSha256 && ImageNodes.naturalRect(w.props) == before)
        #expect(!FileManager.default.fileExists(atPath: session.file.path) && w.editing.sessions.isEmpty)
    }

    @Test func doneRemovesTheFileAndTheCommandsAndPanelFollowTheSelection() async throws {
        let w = try await World()
        defer { w.close() }
        let commands = w.editing.commands()
        #expect(commands.count == 2 && commands[0].title == "Preview" && commands[0].validation().isEnabled)
        let registry = CommandRegistry()
        for command in commands { registry.replace(command) }
        #expect(registry.perform(commands[1].id))
        let session = try #require(w.editing.sessions.first)
        #expect(w.opened.last?.1.lastPathComponent == "Other.app")
        PanelRendering.host(EditingInPanel(editing: w.editing, document: w.setup.document))
        EditingInPanel.finishing(w.editing, session)()
        #expect(!FileManager.default.fileExists(atPath: session.file.path) && w.editing.sessions.isEmpty)
        PanelRendering.host(EditingInPanel(editing: w.editing, document: w.setup.document))
        // The panel window, made once per document window.
        let panel = try #require(EditingInPanel.show(for: w.setup.window, editing: w.editing))
        #expect(EditingInPanel.show(for: w.setup.window, editing: w.editing) === panel)
        w.setup.window.window?.removeChildWindow(panel)
        // Cancel from the panel; declining the confirmation starts nothing.
        let second = try #require(w.editing.editFromPanel())
        EditingInPanel.cancelling(w.editing, second)()
        await w.setup.document.settle()
        w.editing.confirm = { _ in false }
        #expect(w.editing.editFromPanel() == nil)
        // With the preference off no confirmation is asked; the preferred editor wins.
        let preferences = w.setup.environment.preferences
        w.editing.preferences = preferences
        preferences.set(false, for: PreferenceCatalog.Object.confirmExternalEditor)
        #expect(w.editing.defaultEditor(for: w.props.pixels)?.lastPathComponent == "Preview.app")
        #expect(w.editing.editFromPanel() != nil)
        w.editing.finishAll()
        // Nothing selected, or not an image, or no blob: nothing.
        w.setup.window.selection.model.set(Selection())
        #expect(w.editing.editFromPanel() == nil && !commands[0].validation().isEnabled)
        _ = registry.perform(commands[0].id)
        let rect = await w.setup.document.addRectangles([Rect(x: 0, y: 0, width: 5, height: 5)])[0]
        #expect(w.editing.edit(rect.opID, in: w.setup.window) == nil)
        w.editing.cached = { _ in nil }
        #expect(w.editing.edit(w.image, in: w.setup.window) == nil)
        // The Object panel button.
        let inspector = InspectorRegistry()
        ExternalEditing.register(into: inspector, editing: w.editing)
        let model = ObjectPanelModel(document: w.setup.document, selection: Selection([SelectionID(w.image)]))
        let views = inspector.views(for: model)
        #expect(views.map(\.id) == ["imageEdit"])
        PanelRendering.host(VStack { ForEach(views, id: \.id) { $0.view } })
        let two = ObjectPanelModel(document: w.setup.document, selection: Selection([SelectionID(w.image), SelectionID(w.image)]))
        _ = inspector.views(for: two)
        #expect(ExternalEditing.type(of: Wiretuner_Doc_V1_PixelSource()) == .image)
        // A window without an NSWindow has no panel.
        w.editing.directory = { URL(fileURLWithPath: "/dev/null/nope") }
        w.editing.cached = { _ in w.original }
        w.setup.window.selection.model.set(Selection([SelectionID(w.image)]))
        #expect(w.editing.editFromPanel() == nil, "a folder that cannot be made starts nothing")
    }
}
