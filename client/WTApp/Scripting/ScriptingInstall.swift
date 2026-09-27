import AppKit
import WTInterchange
import WTModel

/// The scripting dictionary's hold on the app (DOC-026): the application's `document` elements,
/// `make new document`, and the window-level verbs over the document controller, the library,
/// export and print.
extension AppDelegate {
    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        key == "scriptDocuments"
    }

    /// The application's `document` elements: every open document (a typeface's glyph tabs are
    /// views of their document, not documents).
    @objc var scriptDocuments: [WTScriptDocument] {
        ScriptingHost.shared.documents().map(ScriptingHost.shared.document)
    }

    /// `make new document [with properties {name: …}]`.
    @objc(insertInScriptDocuments:)
    func insertScriptDocument(_ document: WTScriptDocument) {
        guard let handle = ScriptingHost.shared.create(document.name) else {
            return ScriptRun.fail(ScriptFailure(ScriptFailure.notHandled, "The document could not be created"))
        }
        if let command = NSScriptCommand.current() {
            command.suspendExecution()
            let event = ScriptEvent(command: command)
            Task { @MainActor in
                await handle.settle()
                event.command.resumeExecution(withResult: ScriptingHost.shared.document(handle))
            }
        }
    }

    func installScripting() {
        let host = ScriptingHost.shared
        let documents = documents!
        let library = library
        let account = account
        host.documents = { documents.documents.filter { $0.canvasNode == nil } }
        host.open = { text in
            if let open = documents.documents.first(where: { $0.canvasNode == nil && ($0.id == text || $0.title == text) }) {
                documents.open(open)
                return open
            }
            let candidates = library.cache.documents.values.filter { !$0.isTrashed && ($0.id == text || $0.name == text) }
            guard let entry = candidates.first(where: { $0.id == text }) ?? candidates.sorted(by: LibraryCacheFile.byName).first,
                  library.isAvailable(entry) else { return nil }
            library.open([entry])
            return documents.document(id: entry.id)
        }
        host.openFile = { [weak self] url in self?.open(url) ?? false }
        host.create = { name in documents.document(id: library.createDocument(name: name.isEmpty ? LibraryModel.untitled : name).id) }
        host.close = { documents.close($0.id) }
        host.isOnline = { library.isOnline && account.isSignedIn }
        host.role = { library.cache.documents[$0.id]?.role }
        host.goToPage = { handle, number in
            guard let window = documents.views(of: handle.id).first, number >= 1, number <= handle.pageList.pages.count else { return false }
            window.goToPage(number - 1)
            return true
        }
        host.export = ScriptingHost.exporting(through: exports) { documents.views(of: $0.id).first }
        host.print = { [weak self] handle, preset, label in
            let show: @MainActor () -> String? = { [weak self] in
                guard let window = documents.views(of: handle.id).first else { return "The document has no window" }
                window.showWindow(nil)
                window.window?.makeKeyAndOrderFront(nil)
                return self?.menuTarget?.perform(StandardCommands.ID.print) == true ? nil : "Print is not available for this document"
            }
            guard let preset else { return show() }
            return ScriptPrinting.print(handle, preset: preset, label: label, show: show)
        }
        let intents = IntentsHost.shared
        intents.libraryDocuments = {
            let recents = library.cache.recentDocuments
            let rest = library.cache.documents.values.filter { document in !recents.contains { $0.id == document.id } }.sorted(by: LibraryCacheFile.byName)
            return recents + rest
        }
        let templates = templates
        intents.create = { name, templateID in
            let name = name.isEmpty ? LibraryModel.untitled : name
            guard let templateID else {
                if templates.defaultTemplateID == nil { return host.create(name) }
                return documents.document(id: await templates.newDocument(name: name).id)
            }
            let template = DocumentCreation.Template.document(try await templates.states.state(of: templateID), name: library.cache.documents[templateID]?.name ?? "")
            return documents.document(id: library.createDocument(name: name, template: template).id)
        }
        let collaboration = collaboration
        host.shareLink = { handle in
            // A new viewer link, its token remembered as the Share sheet's are (COLLAB-013).
            let created = try await collaboration.shares.createLink(documentID: handle.id, options: ShareLinkOptions(), accessToken: try await collaboration.accessToken())
            collaboration.linkTokens[created.link.id] = created.token
            return LinkConfiguration.shareURL(base: collaboration.links, token: created.token).absoluteString
        }
    }
}
