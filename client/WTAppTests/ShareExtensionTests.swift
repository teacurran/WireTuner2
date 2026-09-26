import AppKit
import Foundation
import Security
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WTModel
@testable import WireTuner

/// IMG-026: the share extension's hand-off (`ShareHandoff`, compiled into the app too), its inbox
/// writer, the chooser (the Library's picker) and the extension as embedded in the app: its
/// activation rule and its sandbox -- the app group, no network.
@Suite(.serialized) @MainActor struct ShareExtensionTests {
    static func folder() -> URL {
        let url = TestStores.directory()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let pdf: Data = {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 20, height: 20)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 2, y: 2, width: 10, height: 10))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }()

    // MARK: The hand-off URL

    @Test func theHandOffURLRoundTrips() throws {
        let id = UUID()
        let url = ShareHandoff.url(inbox: id, app: "Photos & Co", option: true)
        #expect(url.scheme == "wiretuner-share" && url.host() == "inbox")
        let parsed = try #require(ShareHandoff.parse(url))
        #expect(parsed.id == id.uuidString && parsed.app == "Photos & Co" && parsed.option)
        let plain = try #require(ShareHandoff.parse(ShareHandoff.url(inbox: id, app: "", option: false)))
        #expect(plain.app == "another app" && !plain.option)
        #expect(ShareHandoff.parse(URL(string: "wiretuner-share://inbox/")!) == nil)
        #expect(ShareHandoff.parse(URL(string: "wiretuner-share://other/\(id.uuidString)")!) == nil)
        #expect(ShareInbox.parse(url)?.id == id.uuidString && ShareInbox.scheme == ShareHandoff.scheme)
        #expect(ShareHandoff.inboxRoot().map { $0.lastPathComponent == "Inbox" } ?? true)
        #expect(ShareHandoff.groupIdentifier(["WTAppGroup": "TEAM.com.villagecompute.wiretuner"]) == "TEAM.com.villagecompute.wiretuner")
        #expect(ShareHandoff.groupIdentifier(nil) == "com.villagecompute.wiretuner" && ShareHandoff.groupIdentifier(["WTAppGroup": ""]) == "com.villagecompute.wiretuner")
        #expect(ShareHandoff.appGroup.hasSuffix("com.villagecompute.wiretuner"))
    }

    @Test func acceptedTypesAndFileNames() {
        #expect(ShareHandoff.acceptedType(of: ["public.jpeg", "public.file-url"]) == .jpeg)
        #expect(ShareHandoff.acceptedType(of: ["com.adobe.pdf"]) == .pdf)
        #expect(ShareHandoff.acceptedType(of: ["public.png", "public.svg-image"]) == .svg, "SVG is preferred to a raster of it")
        #expect(ShareHandoff.acceptedType(of: ["public.plain-text", "not a type"]) == nil)
        #expect(ShareHandoff.acceptedType(ofFile: URL(fileURLWithPath: "/a/b.PDF")) == .pdf)
        #expect(ShareHandoff.acceptedType(ofFile: URL(fileURLWithPath: "/a/b.txt")) == nil)
        #expect(ShareHandoff.fileName(index: 0, suggested: "Beach.JPG", type: .jpeg) == "01 Beach.jpeg")
        #expect(ShareHandoff.fileName(index: 11, suggested: nil, type: .png) == "12 Shared Item.png")
        #expect(ShareHandoff.fileName(index: 1, suggested: "a/b:c", type: .pdf) == "02 a-b-c.pdf")
        #expect(ShareHandoff.fileName(index: 2, suggested: ".hidden", type: .svg) == "03 Shared Item.svg")
        #expect(ShareHandoff.fileName(index: 3, suggested: "x", type: UTType(exportedAs: "com.example.none")) == "04 x.data")
    }

    // MARK: The inbox writer

    @Test func theWriterCopiesAcceptedItemsInShareOrder() async throws {
        let files = ImportFiles()
        defer { files.remove() }
        let png = files.png("Photo.png")
        let svg = files.text("Drawing.svg", ImportFiles.staticSVG)
        let text = files.text("Notes.txt", "hello")
        let fileProvider = NSItemProvider(item: svg as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let dataProvider = NSItemProvider(item: Self.pdf as NSData, typeIdentifier: UTType.pdf.identifier)
        dataProvider.suggestedName = "Invoice"
        let providers = [try #require(NSItemProvider(contentsOf: png)), dataProvider, fileProvider,
                         NSItemProvider(item: "words" as NSString, typeIdentifier: UTType.plainText.identifier),
                         NSItemProvider(item: text as NSURL, typeIdentifier: UTType.fileURL.identifier)]
        let items = ShareInboxWriter.items(providers)
        #expect(items.count == 4, "text is refused; a text file is refused when it is copied")
        let root = Self.folder()
        let id = try await ShareInboxWriter(root: root).write(items)
        let written = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: id.uuidString).path).sorted()
        // A provider over a file hands it over under a name of the system's choosing when it has no
        // suggested name.
        #expect(written.count == 3 && written[0].hasPrefix("01 ") && written[0].hasSuffix(".png"))
        #expect(Array(written.dropFirst()) == ["02 Invoice.pdf", "03 Drawing.svg"])
        #expect(try Data(contentsOf: root.appending(path: id.uuidString).appending(path: "02 Invoice.pdf")) == Self.pdf)
        // At most twenty items; nothing accepted writes nothing.
        #expect(ShareInboxWriter.items(Array(repeating: dataProvider, count: 25)).count == ShareHandoff.maximumItems)
        let refused = ShareInboxWriter.items([NSItemProvider(item: text as NSURL, typeIdentifier: UTType.fileURL.identifier)])
        let empty = UUID()
        await #expect(throws: ShareInboxWriter.WriteError.nothingAccepted) { try await ShareInboxWriter(root: root).write(refused, id: empty) }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: empty.uuidString).path))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The chooser

    @Test func optionOrNoWindowAsksTheChooser() async throws {
        let image = ImageWorld()
        defer { image.close() }
        let root = Self.folder()
        let inbox = ShareInbox(root: root)
        let imports = image.world.imports
        inbox.place = { urls, window, app in await ShareInbox.place(urls, on: window, from: app, imports: imports) }
        inbox.window = { image.window }
        final class Chooser {
            var asked: [String] = []
            var answer: DocumentWindowController?
        }
        let chooser = Chooser()
        inbox.choose = { app in
            chooser.asked.append(app)
            return chooser.answer
        }
        func share(option: Bool) throws -> URL {
            let id = UUID()
            let folder = root.appending(path: id.uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(contentsOf: image.world.files.png()).write(to: folder.appending(path: "01 a.png"))
            return ShareHandoff.url(inbox: id, app: "Preview", option: option)
        }
        // Cancelled: nothing placed, the folder is gone.
        let cancelled = try share(option: true)
        #expect(await inbox.drain(cancelled) == 0 && chooser.asked == ["Preview"])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ShareHandoff.parse(cancelled)!.id).path))
        chooser.answer = image.window
        let chosen = try share(option: true), front = try share(option: false)
        #expect(await inbox.drain(chosen) == 1 && chooser.asked.count == 2)
        // A front window and no Option: no question.
        #expect(await inbox.drain(front) == 1 && chooser.asked.count == 2)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func thePickerChoosesADocumentANewOneOrNothing() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let library = LibraryModel(services: FakeLibraryServer().services(), store: nil, thumbnails: ThumbnailCache(directory: nil))
        let documents = world.documents
        library.onOpen = { opened in
            for document in opened { documents.open(documents.environment.makeDocument(id: document.id, title: document.name), show: false) }
        }
        let poster = library.createDocument(name: "Poster")
        #expect(documents.windowControllers[poster.id] != nil)
        documents.close(poster.id)
        var created = 0
        let newDocument: @MainActor () -> DocumentWindowController? = {
            created += 1
            return world.window
        }
        // The picker's model: recent documents the account may edit, the first selected.
        let model = LibraryPickerModel(prompt: "Add", library: library)
        #expect(model.documents.map(\.id) == [poster.id] && model.selection == poster.id && model.canAdd)
        #expect(LibraryPickerModel.canEdit(nil) && LibraryPickerModel.canEdit(.editor) && !LibraryPickerModel.canEdit(.viewer))
        var choices: [LibraryPickerModel.Choice] = []
        model.finish = { choices.append($0) }
        model.add()
        model.newDocument()
        model.cancel()
        model.selection = nil
        model.add()
        #expect(choices == [.document(poster), .newDocument, .cancel])
        _ = NSHostingView(rootView: LibraryPickerView(model: model)).fittingSize
        _ = NSHostingView(rootView: LibraryPickerView(model: LibraryPickerModel(prompt: "Empty", library: LibraryModel(services: FakeLibraryServer().services(), store: nil, thumbnails: ThumbnailCache(directory: nil))))).fittingSize
        // The window: shown, answered, closed.
        var shown: NSWindow?
        let chosen = await LibraryPicker.choose(prompt: "Add the items from Photos to", library: library) { window, model in
            shown = window
            model.newDocument()
            model.cancel()
        }
        #expect(chosen == .newDocument && shown?.identifier == LibraryPicker.windowIdentifier && shown?.isVisible == false)
        // The app's chooser opens the chosen document and returns its window.
        let opened = await ShareInbox.choose(from: "Photos", library: library, documents: documents, newDocument: newDocument) { prompt, _ in
            #expect(prompt == "Add the items from Photos to")
            return .document(poster)
        }
        #expect(opened === documents.windowControllers[poster.id] && opened != nil)
        documents.close(poster.id)
        #expect(await ShareInbox.choose(from: "Photos", library: library, documents: documents, newDocument: newDocument) { _, _ in .newDocument } === world.window && created == 1)
        #expect(await ShareInbox.choose(from: "Photos", library: library, documents: documents, newDocument: newDocument) { _, _ in .cancel } == nil)
        // The app's default picker: its own window, answered here by btn:[Cancel].
        let answering = Task { @MainActor in
            _ = await eventually { NSApp.windows.contains { $0.identifier == LibraryPicker.windowIdentifier && $0.isVisible } }
            let picker = NSApp.windows.first { $0.identifier == LibraryPicker.windowIdentifier && $0.isVisible }
            (picker?.contentViewController as? NSHostingController<LibraryPickerView>)?.rootView.model.cancel()
        }
        #expect(await ShareInbox.choose(from: "Mail", library: library, documents: documents, newDocument: newDocument) == nil)
        await answering.value
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        LibraryPicker.show(window, model)
        #expect(window.isVisible)
        window.close()
    }

    // MARK: The embedded extension

    @Test func theExtensionIsEmbeddedSandboxedWithTheGroupAndNoNetwork() throws {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let appex = plugins.appending(path: "WireTunerShare.appex")
        let bundle = try #require(Bundle(url: appex))
        let info = try #require(bundle.infoDictionary?["NSExtension"] as? [String: Any])
        #expect(info["NSExtensionPointIdentifier"] as? String == "com.apple.share-services")
        let rule = try #require((info["NSExtensionAttributes"] as? [String: Any])?["NSExtensionActivationRule"] as? String)
        for type in ["public.image", "public.svg-image", "com.adobe.pdf"] { #expect(rule.contains(type)) }
        #expect(rule.contains("BETWEEN {1, 20}"))
        #expect(bundle.infoDictionary?["CFBundleDisplayName"] as? String == "Add to WireTuner Document")
        // The signature's entitlements (the app is signed ad hoc in tests): sandboxed, the group,
        // and nothing that opens a socket.
        var code: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(appex as CFURL, [], &code) == errSecSuccess)
        var signing: CFDictionary?
        #expect(SecCodeCopySigningInformation(try #require(code), SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess)
        let entitlements = try #require((signing as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any])
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(entitlements["com.apple.security.application-groups"] as? [String] == [ShareHandoff.appGroup])
        #expect(!entitlements.keys.contains { $0.hasPrefix("com.apple.security.network") })
    }
}
