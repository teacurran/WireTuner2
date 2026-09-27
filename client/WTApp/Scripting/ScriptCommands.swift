import AppKit
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender

// DOC-026: the dictionary's verbs beyond key-value coding (scripting.adoc, "AppleScript").  Each
// resolves its direct parameter to the wrappers of `ScriptableObjects.swift` and runs one `WTModel`
// command through `ScriptRun`; the window-level verbs (open, print, export, share link, go to
// page) go to `ScriptingHost`.

/// A suspended Apple event carried to the task that resumes it (on the main actor, where Cocoa
/// scripting runs).
struct ScriptEvent: @unchecked Sendable {
    let command: NSScriptCommand
}

/// A command's result carried out of `MainActor.assumeIsolated`.
struct ResultBox: @unchecked Sendable {
    let value: Any?
}

/// A script command's objects: the direct parameter (and `key`'s argument) evaluated.
enum ScriptCommandArguments {
    static func objects(_ value: Any?) -> [Any] {
        switch value {
        case let specifier as NSScriptObjectSpecifier:
            let resolved = specifier.objectsByEvaluatingSpecifier
            return (resolved as? [Any]) ?? resolved.map { [$0] } ?? []
        case let list as [Any]: return list.flatMap(objects)
        case let object?: return [object]
        case nil: return []
        }
    }

    static func first<T>(_ type: T.Type, _ value: Any?) -> T? { objects(value).compactMap { $0 as? T }.first }
    static func all<T>(_ type: T.Type, _ value: Any?) -> [T] { objects(value).compactMap { $0 as? T } }

    static func document(of command: NSScriptCommand) -> WTScriptDocument? {
        first(WTScriptDocument.self, command.directParameter) ?? first(WTScriptDocument.self, command.evaluatedReceivers)
    }
}

/// `open "Brochure"` (a library document's name or id) or `open file …`.
@objc(WTScriptOpenCommand)
final class WTScriptOpenCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let event = ScriptEvent(command: self)
        return MainActor.assumeIsolated { ResultBox(value: (event.command as! Self).run()) }.value
    }

    @MainActor
    func run() -> Any? {
        let host = ScriptingHost.shared
        var opened: [WTScriptDocument] = []
        for item in ScriptCommandArguments.objects(directParameter) {
            if let url = item as? URL {
                if !host.openFile(url) { ScriptRun.fail(ScriptFailure(ScriptFailure.noSuchObject, "\(url.lastPathComponent) could not be opened")) }
            } else if let text = item as? String {
                guard let handle = host.open(text) else {
                    ScriptRun.fail(ScriptFailure(host.isOnline() ? ScriptFailure.noSuchObject : ScriptFailure.offline,
                                                 host.isOnline() ? "No document is named “\(text)”" : "“\(text)” is not on this Mac; opening it needs a connection"))
                    continue
                }
                opened.append(host.document(handle))
            }
        }
        return opened.count == 1 ? opened[0] : opened.isEmpty ? nil : opened
    }
}

/// `duplicate graphic 1 of document 1`: a copy on the same layer, one change per object.
@objc(WTScriptDuplicateCommand)
final class WTScriptDuplicateCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let event = ScriptEvent(command: self)
        return MainActor.assumeIsolated { ResultBox(value: (event.command as! Self).run()) }.value
    }

    @MainActor
    func run() -> Any? {
        let graphics = ScriptCommandArguments.all(WTScriptGraphic.self, directParameter)
        guard !graphics.isEmpty else {
            ScriptRun.fail(ScriptFailure(ScriptFailure.notHandled, "Scripts can duplicate graphics in version 1"))
            return nil
        }
        for graphic in graphics {
            guard let node = graphic.node, let document = graphic.document, let handle = document.handle else { continue }
            do {
                let edit = try ScriptObjects.calling(node, "duplicate", nil, in: document.state)
                ScriptRun.perform(edit.command, label: "duplicate", on: handle) { change in
                    change?.createdObjects.first.map { WTScriptGraphic.make(document: document, node: $0) }
                }
            } catch {
                ScriptRun.fail(error)
            }
        }
        return nil
    }
}

/// `print document 1 [print preset "…"]`.
@objc(WTScriptPrintCommand)
final class WTScriptPrintCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let event = ScriptEvent(command: self)
        return MainActor.assumeIsolated { ResultBox(value: (event.command as! Self).run()) }.value
    }

    @MainActor
    func run() -> Any? {
        guard let handle = ScriptCommandArguments.document(of: self)?.handle else {
            ScriptRun.fail(ScriptFailure(ScriptFailure.noSuchObject, "Print needs a document"))
            return nil
        }
        if let message = ScriptingHost.shared.print(handle, evaluatedArguments?["Preset"] as? String) {
            ScriptRun.fail(ScriptFailure(ScriptFailure.notHandled, message))
        }
        return nil
    }
}

/// `add page document 1 [count n] [page size {w, h}] [master page m]`.
@objc(WTScriptAddPageCommand)
final class WTScriptAddPageCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let event = ScriptEvent(command: self)
        return MainActor.assumeIsolated { ResultBox(value: (event.command as! Self).run()) }.value
    }

    @MainActor
    func run() -> Any? {
        guard let document = ScriptCommandArguments.document(of: self), let handle = document.handle else {
            ScriptRun.fail(ScriptFailure(ScriptFailure.noSuchObject, "Add Page needs a document"))
            return nil
        }
        let arguments = evaluatedArguments ?? [:]
        let size = ScriptRun.numbers(arguments["Size"]).flatMap { $0.count == 2 ? Size(width: $0[0], height: $0[1]) : nil }
        let master = ScriptCommandArguments.first(WTScriptMasterPage.self, arguments["Master"])?.node
        do {
            let count = (arguments["Count"] as? NSNumber)?.intValue ?? 1
            ScriptRun.perform(try ScriptObjects.addPages(count: count, size: size, master: master), label: "add page", on: handle)
        } catch {
            ScriptRun.fail(error)
        }
        return nil
    }
}

/// `go to page (page 3 of document 1)`.
@objc(WTScriptGoToPageCommand)
final class WTScriptGoToPageCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let event = ScriptEvent(command: self)
        return MainActor.assumeIsolated { ResultBox(value: (event.command as! Self).run()) }.value
    }

    @MainActor
    func run() -> Any? {
        guard let page = ScriptCommandArguments.first(WTScriptPage.self, directParameter), let handle = page.document?.handle,
              ScriptingHost.shared.goToPage(handle, page.scriptIndex)
        else {
            ScriptRun.fail(ScriptFailure(ScriptFailure.noSuchObject, "Go to Page needs a page of an open document"))
            return nil
        }
        return nil
    }
}

/// `apply master page (master page 1 of document 1) to (pages 2 thru 4 of document 1)`.
@objc(WTScriptApplyMasterCommand)
final class WTScriptApplyMasterCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let event = ScriptEvent(command: self)
        return MainActor.assumeIsolated { ResultBox(value: (event.command as! Self).run()) }.value
    }

    @MainActor
    func run() -> Any? {
        let pages = ScriptCommandArguments.all(WTScriptPage.self, evaluatedArguments?["Pages"]).compactMap(\.node)
        guard let master = ScriptCommandArguments.first(WTScriptMasterPage.self, directParameter), let node = master.node,
              let handle = master.document?.handle, !pages.isEmpty
        else {
            ScriptRun.fail(ScriptFailure(ScriptFailure.noSuchObject, "Apply Master Page needs a master page and pages"))
            return nil
        }
        ScriptRun.perform(ApplyMasterPage(node, to: pages), label: "apply master page", on: handle)
        return nil
    }
}

/// `release child page (page 2 of document 1)`.
@objc(WTScriptReleaseCommand)
final class WTScriptReleaseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let event = ScriptEvent(command: self)
        return MainActor.assumeIsolated { ResultBox(value: (event.command as! Self).run()) }.value
    }

    @MainActor
    func run() -> Any? {
        let pages = ScriptCommandArguments.all(WTScriptPage.self, directParameter)
        guard let document = pages.first?.document, let handle = document.handle else {
            ScriptRun.fail(ScriptFailure(ScriptFailure.noSuchObject, "Release Child Page needs pages"))
            return nil
        }
        ScriptRun.perform(ReleaseChildPages(pages.compactMap(\.node), in: document.state), label: "release child page", on: handle)
        return nil
    }
}

/// `find and replace text document 1 find "a" replacing with "b"` → the count.
@objc(WTScriptFindReplaceCommand)
final class WTScriptFindReplaceCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let event = ScriptEvent(command: self)
        return MainActor.assumeIsolated { ResultBox(value: (event.command as! Self).run()) }.value
    }

    @MainActor
    func run() -> Any? {
        guard let document = ScriptCommandArguments.document(of: self), let handle = document.handle else {
            ScriptRun.fail(ScriptFailure(ScriptFailure.noSuchObject, "Find and Replace needs a document"))
            return nil
        }
        let arguments = evaluatedArguments ?? [:]
        guard let find = arguments["Find"] as? String, !find.isEmpty else {
            ScriptRun.fail(ScriptFailure(ScriptFailure.invalidParameter, "Find and Replace needs text to find"))
            return nil
        }
        guard let replace = ScriptObjects.findAndReplace(
            find, with: arguments["Replace"] as? String ?? "", wholeWord: (arguments["WholeWord"] as? NSNumber)?.boolValue ?? false,
            matchCase: (arguments["MatchCase"] as? NSNumber)?.boolValue ?? false, in: document.state
        ) else { return 0 }
        ScriptRun.perform(replace.command, label: "find and replace text", on: handle) { _ in replace.count }
        return replace.count
    }
}

/// `export document 1 as "pdf" to file "…"`.
@objc(WTScriptExportCommand)
final class WTScriptExportCommand: NSScriptCommand {
    /// The format a script names: the file extension or the display name, any case.
    static func format(_ name: String) -> ExportFormat? {
        let name = name.lowercased()
        return ExportFormat.allCases.first { $0.fileExtension.lowercased() == name || $0.displayName.lowercased() == name }
            ?? (name == "jpg" ? .jpeg : nil)
    }

    override func performDefaultImplementation() -> Any? {
        let event = ScriptEvent(command: self)
        return MainActor.assumeIsolated { ResultBox(value: (event.command as! Self).run()) }.value
    }

    @MainActor
    func run() -> Any? {
        let arguments = evaluatedArguments ?? [:]
        guard let handle = ScriptCommandArguments.document(of: self)?.handle, let url = arguments["File"] as? URL else {
            ScriptRun.fail(ScriptFailure(ScriptFailure.invalidParameter, "Export needs a document and a file"))
            return nil
        }
        guard let format = Self.format(arguments["Format"] as? String ?? "") else {
            ScriptRun.fail(ScriptFailure(ScriptFailure.invalidParameter, "Unknown export format “\(arguments["Format"] as? String ?? "")”"))
            return nil
        }
        suspendExecution()
        let event = ScriptEvent(command: self)
        Task { @MainActor in
            if let message = await ScriptingHost.shared.export(handle, format, url) {
                event.command.scriptErrorNumber = ScriptFailure.invalidParameter
                event.command.scriptErrorString = message
            }
            event.command.resumeExecution(withResult: nil)
        }
        return nil
    }
}

/// `share link document 1` → the link; offline it fails with `errOfflineRequired` (1001).
@objc(WTScriptShareLinkCommand)
final class WTScriptShareLinkCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let event = ScriptEvent(command: self)
        return MainActor.assumeIsolated { ResultBox(value: (event.command as! Self).run()) }.value
    }

    @MainActor
    func run() -> Any? {
        let host = ScriptingHost.shared
        guard let handle = ScriptCommandArguments.document(of: self)?.handle else {
            ScriptRun.fail(ScriptFailure(ScriptFailure.noSuchObject, "Share Link needs a document"))
            return nil
        }
        guard host.isOnline() else {
            ScriptRun.fail(ScriptFailure(ScriptFailure.offline, "Share Link needs a connection"))
            return nil
        }
        suspendExecution()
        let event = ScriptEvent(command: self)
        Task { @MainActor in
            do {
                event.command.resumeExecution(withResult: try await host.shareLink(handle))
            } catch {
                let failure = ScriptFailure(error)
                event.command.scriptErrorNumber = failure.number
                event.command.scriptErrorString = failure.message
                event.command.resumeExecution(withResult: nil)
            }
        }
        return nil
    }
}
