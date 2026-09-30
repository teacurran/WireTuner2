import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
@testable import WireTuner

/// Holds a publish at one step, on the thread doing it, until the test lets it go.
final class PublishGate: @unchecked Sendable {
    private let lock = NSLock()
    private let held = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let holds: @Sendable (HTMLPublishStep) -> Bool
    private var seen: [HTMLPublishStep] = []
    private var onMain = false
    private var holding = false

    /// Holds at `step`; with none, never holds.
    convenience init(at step: HTMLPublishStep? = nil) { self.init { $0 == step } }

    /// Holds at the first step `holds` accepts.
    init(where holds: @escaping @Sendable (HTMLPublishStep) -> Bool) { self.holds = holds }

    /// The hook: records the step and, at the chosen one, waits (ten seconds at most).
    var observe: @Sendable (HTMLPublishStep) -> Void {
        { [self] step in
            let hold = lock.withLock {
                seen.append(step)
                if Thread.isMainThread { onMain = true }
                guard !holding, holds(step) else { return false }
                holding = true
                return true
            }
            if hold {
                held.signal()
                _ = release.wait(timeout: .now() + 10)
            }
        }
    }

    var steps: [HTMLPublishStep] { lock.withLock { seen } }
    /// Whether any step ran on the main thread.
    var ranOnMain: Bool { lock.withLock { onMain } }

    /// Waits (off the main actor) until the publish reaches the chosen step.
    func reached() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: self.held.wait(timeout: .now() + 10) == .success) }
        }
    }

    func letGo() { release.signal() }
}

/// What a person does in a sheet from the keyboard: Return presses the default button
/// (btn:[Publish], btn:[OK]) and Escape the cancel button (btn:[Cancel], btn:[Close]), through the
/// sheet's own key-equivalent handling.  (SwiftUI builds no accessibility tree to press buttons
/// through until an assistive app connects.)
@MainActor
enum SheetKeys {
    static func press(_ characters: String, keyCode: UInt16, in window: NSWindow) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return false }
        return window.performKeyEquivalent(with: event)
    }

    /// Return: the default button.
    @discardableResult
    static func returnKey(in window: NSWindow) -> Bool { press("\r", keyCode: 36, in: window) }

    /// Escape: the cancel button.
    @discardableResult
    static func escape(in window: NSWindow) -> Bool { press("\u{1b}", keyCode: 53, in: window) }
}

/// The whole of Publish as HTML as a person does it, on real sheets on a shown document window:
/// choose a folder, publish, publish again to the same folder, cancel one mid-way, open the Setup
/// sheet from the Publish sheet, a collaborator's change arriving in both, and a relaunch that
/// finds the folder again from its bookmark.  The earlier tests caught sheets in a list and
/// answered the folder panel directly, which hid that the panel went behind the sheet.
@Suite(.serialized) @MainActor struct PublishFlowTests {
    /// A shown document window whose sheets are real; the Finder and the browser recorded.
    @MainActor
    final class Flow {
        let setup = SetupWindow()
        let root = TestStores.directory()
        let folder: URL
        var features: WebFeatures
        let revealed = TestBox<[URL]>([])
        let opened = TestBox<[(URL, URL?)]>([])
        let panels = TestBox<[NSWindow?]>([])

        init() throws {
            folder = root.appending(path: "Site Folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            features = WebFeatures(preferences: setup.environment.preferences)
            configure(features)
            setup.window.window?.orderFront(nil)
        }

        var window: DocumentWindowController { setup.window }
        var document: DocumentHandle { setup.document }
        var nswindow: NSWindow { setup.window.window! }

        /// The app's features as a launch installs them, with the Finder and browser recorded and
        /// the folder panel answering `folder` -- after checking where it would appear.
        func configure(_ features: WebFeatures) {
            let revealed = revealed, opened = opened, panels = panels, folder = folder
            features.reveal = { revealed.value += $0 }
            features.open = { opened.value.append(($0, $1)) }
            features.chooseFolder = { window in
                panels.value.append(ModalUI.host(window))
                return folder
            }
            features.browsers.installed = { [URL(filePath: "/Applications/Safari.app"), URL(filePath: "/Applications/Firefox.app")] }
            features.browsers.defaultBrowser = { URL(filePath: "/Applications/Safari.app") }
            let blobs = root.appending(path: "blobs")
            features.blobs.directory = { blobs }
            let window = setup.window
            features.install(commands: setup.environment.commands, panels: setup.environment.panels, extensions: ExtensionRegistry()) { [weak window] in window }
        }

        func sheet(_ identifier: String) -> NSWindow? { features.sheets[identifier] }

        /// A collaborator's change, received as the sync client would.
        func remote(_ command: some WTModel.Command) async throws {
            var other = DocumentCore(state: document.state, replica: 0xC0_11AB)
            let change = try #require(try other.perform(command, recording: DocumentCore.Recording(limit: 1, now: Date()))?.change)
            _ = await document.receive(change).value
            await document.settle()
        }

        func close() {
            for id in Array(features.sheets.keys) { features.dismiss(id) }
            features.detach(window)
            nswindow.orderOut(nil)
            setup.close()
        }
    }

    /// Every file in `folder`, relative path to bytes.
    static func contents(_ folder: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            result[String(path.dropFirst(base.count).drop { $0 == "/" })] = try? Data(contentsOf: url)
        }
        return result
    }

    /// The hidden folders publishes assemble in, left beside `folder`.
    static func leftovers(_ folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path(percentEncoded: false))) ?? []
        return names.filter { $0.hasPrefix(".\(folder.lastPathComponent).publishing-") }
    }

    @Test func aPersonPublishesOnRealSheetsRepublishesCancelsAndRelaunches() async throws {
        let flow = try Flow()
        defer { flow.close() }
        let page = flow.setup.page.rect
        _ = await flow.document.addRectangles([Rect(x: page.minX + 20, y: page.minY + 20, width: 40, height: 40)])
        await flow.document.settle()

        // menu:File[Publish as HTML…]: the sheet is on the document window.
        flow.setup.environment.commands.perform(WebFeatures.ID.publish)
        let sheet = try #require(flow.sheet(WebFeatures.publishSheet))
        #expect(await eventually { flow.nswindow.attachedSheet === sheet })
        let model = try #require(sheet.contentViewController.flatMap { ($0 as? NSHostingController<PublishSheet>)?.rootView.model })

        // Publish with no folder: the folder panel is asked for on the Publish sheet (the bug:
        // it went on the document window, behind the sheet), and the bundle goes into it.
        #expect(model.folder == nil)
        #expect(SheetKeys.returnKey(in: sheet), "Return presses Publish")
        #expect(await eventually { if case .done = model.phase { true } else { false } })
        #expect(flow.panels.value.count == 1 && flow.panels.value.first! === sheet)
        let bundle = try #require(model.folder)
        #expect(bundle == flow.folder.appending(path: "Setup"))
        let first = Self.contents(bundle)
        #expect(first["index.html"] != nil && first["pages/page-1.svg"] != nil)
        #expect(flow.revealed.value == [bundle] && flow.opened.value.isEmpty)
        #expect(flow.features.bookmarkedFolder(for: bundle.path(percentEncoded: false)) != nil, "the chosen folder is remembered")

        // Publish again to the same folder: the same files, the unchanged ones not rewritten.
        let style = bundle.appending(path: "style.css")
        let date = Date(timeIntervalSince1970: 2_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: style.path(percentEncoded: false))
        model.openWhenDone = true
        PublishSheet.browser(model).wrappedValue = .application(URL(filePath: "/Applications/Firefox.app"))
        #expect(await eventually { model.browserChoice == .application(URL(filePath: "/Applications/Firefox.app")) })
        await model.publish()?.value
        #expect(model.phase == .done(bundle) && Self.contents(bundle) == first && Self.leftovers(bundle).isEmpty)
        #expect((try FileManager.default.attributesOfItem(atPath: style.path(percentEncoded: false))[.modificationDate] as? Date) == date)
        let opened = try #require(flow.opened.value.last)
        #expect(opened.0 == bundle.appending(path: "index.html") && opened.1?.lastPathComponent == "Firefox.app")

        // Cancel mid-way: the folder keeps the previous bundle, nothing is left beside it.
        _ = await flow.document.addRectangles([Rect(x: page.minX + 100, y: page.minY + 20, width: 30, height: 30)])
        await flow.document.settle()
        let gate = PublishGate { if case .writing(2, _) = $0 { true } else { false } }
        flow.features.observePublish = gate.observe
        let task = model.publish()
        #expect(await gate.reached())
        #expect(model.phase == .publishing)
        #expect(SheetKeys.escape(in: sheet), "Escape presses Cancel")
        #expect(model.cancelling)
        gate.letGo()
        await task?.value
        #expect(model.phase == .ready && !model.cancelling)
        #expect(Self.contents(bundle) == first && Self.leftovers(bundle).isEmpty)
        #expect(!gate.ranOnMain)
        flow.features.observePublish = { _ in }

        // btn:[Setup…] opens the HTML Setup sheet on the Publish sheet, where a person sees it.
        PublishSheet.setup(model)()
        let setupSheet = try #require(flow.sheet(WebFeatures.setupSheet))
        #expect(await eventually { sheet.attachedSheet === setupSheet })
        let setup = try #require(setupSheet.contentViewController.flatMap { ($0 as? NSHostingController<HTMLSetupSheet>)?.rootView.model })
        // Its Location is chosen on the Setup sheet too.
        await setup.chooseLocation()
        #expect(flow.panels.value.last! === setupSheet)
        // A collaborator renames the setting and changes its title while the sheets are open.
        HTMLSetupSheet.option(setup, \.scale, .scale).wrappedValue = 3
        try await flow.remote(RenameHTMLSetting(setup.selected, to: "Client"))
        try await flow.remote(EditHTMLSetting(setup.selected, settings: HTMLPublishSettings(scale: 1, title: "Theirs"), options: [.scale, .title]))
        #expect(setup.name == "Client" && setup.draft.title == "Theirs" && setup.draft.scale == 3, "the field edited here keeps what was typed")
        #expect(model.setting.displayName == "Client" && model.setting.settings.title == "Theirs")
        Render.view(PublishSheet(model: model))
        Render.view(HTMLSetupSheet(model: setup))
        // OK: the Setup sheet goes, the Publish sheet stays.
        await setup.confirm()
        #expect(await eventually { sheet.attachedSheet == nil && flow.nswindow.attachedSheet === sheet })
        #expect(model.setting.settings.scale == 3)

        // A relaunch: new features over this Mac's defaults find the folder from its bookmark,
        // and publishing writes there again.
        let location = model.setting.location
        flow.features.dismiss(WebFeatures.publishSheet)
        #expect(await eventually { flow.nswindow.attachedSheet == nil })
        flow.features.detach(flow.window)
        let relaunched = WebFeatures(preferences: PreferenceStore(defaults: flow.setup.environment.preferences.defaults))
        flow.features = relaunched
        flow.configure(relaunched)
        let resolved = try #require(relaunched.bookmarkedFolder(for: location))
        #expect(resolved.standardizedFileURL.path(percentEncoded: false) == flow.folder.standardizedFileURL.path(percentEncoded: false))
        let again = try #require(relaunched.presentPublish())
        #expect(again.folder == bundle && again.browserChoice == .application(URL(filePath: "/Applications/Firefox.app")))
        await again.publish()?.value
        #expect(again.phase == .done(bundle) && Self.contents(bundle)["pages/page-1.svg"] != first["pages/page-1.svg"])
        #expect(flow.panels.value.count == 2, "no folder panel after the relaunch")
        // btn:[Close].
        #expect(SheetKeys.escape(in: try #require(relaunched.sheets[WebFeatures.publishSheet])), "Escape presses Close")
        #expect(await eventually { flow.nswindow.attachedSheet == nil && relaunched.sheets.isEmpty })
    }

    @Test func fiftyPagesPublishOffTheMainActorWithLiveProgressAndCancelLeavingNoFolder() async throws {
        let flow = try Flow()
        defer { flow.close() }
        _ = await flow.document.perform(AddPages(count: 49)).value
        await flow.document.settle()
        let model = try #require(flow.features.presentPublish())
        #expect(model.pageCount == 50)
        await model.chooseFolder()
        await flow.document.settle()
        let bundle = try #require(model.folder)

        // Cancelled at page 20 of the first publish: no folder at all.
        let gate = PublishGate(at: .rendering(page: 20, of: 50))
        flow.features.observePublish = gate.observe
        let task = model.publish()
        #expect(await gate.reached())
        // The main actor is free while the pages render: the sheet shows the steps as they come.
        #expect(await eventually { model.step == .rendering(page: 19, of: 50) })
        Render.view(PublishSheet(model: model))
        model.cancel()
        Render.view(PublishSheet(model: model))
        gate.letGo()
        await task?.value
        #expect(model.phase == .ready && model.step == .rendering(page: 20, of: 50))
        #expect(!FileManager.default.fileExists(atPath: bundle.path(percentEncoded: false)) && Self.leftovers(bundle).isEmpty)
        #expect(gate.steps == (1...20).map { .rendering(page: $0, of: 50) } && !gate.ranOnMain)

        // The whole publish: every page, then every file.
        let all = PublishGate()
        flow.features.observePublish = all.observe
        await model.publish()?.value
        #expect(model.phase == .done(bundle))
        let files = Self.contents(bundle)
        #expect((1...50).allSatisfy { files["pages/page-\($0).svg"] != nil })
        let rendering = all.steps.filter { if case .rendering = $0 { true } else { false } }
        let writing = all.steps.filter { if case .writing = $0 { true } else { false } }
        #expect(rendering == (1...50).map { .rendering(page: $0, of: 50) })
        #expect(writing == (1...files.count).map { .writing(file: $0, of: files.count) })
        #expect(HTMLPublishStep.rendering(page: 25, of: 50).fraction == 0.45 && HTMLPublishStep.writing(file: 1, of: 1).fraction == 1)
        #expect(HTMLPublishStep.rendering(page: 3, of: 50).label == "Page 3 of 50" && HTMLPublishStep.writing(file: 2, of: 9).label == "Writing file 2 of 9")
    }

    @Test func theSetupSheetCreatesRenamesAndDeletesSettings() async throws {
        let flow = try Flow()
        defer { flow.close() }
        let model = try #require(flow.features.presentSetup())
        let sheet = try #require(flow.sheet(WebFeatures.setupSheet))
        #expect(await eventually { flow.nswindow.attachedSheet === sheet })
        // btn:[+] twice: "Setting 2" and "Setting 3" after the Default, which is materialized.
        HTMLSetupSheet.add(model)()
        #expect(await eventually { model.settings.settings.count == 2 && model.selected == model.settings.settings.last?.id })
        HTMLSetupSheet.add(model)()
        #expect(await eventually { model.settings.settings.map(\.name) == ["Default", "Setting 2", "Setting 3"] && model.name == "Setting 3" })
        // Rename the chosen one and apply.
        HTMLSetupSheet.name(model).wrappedValue = "Print"
        #expect(await model.apply())
        await flow.document.settle()
        #expect(model.settings.settings.map(\.name) == ["Default", "Setting 2", "Print"])
        // btn:[−] deletes it; the Default cannot be deleted.
        HTMLSetupSheet.delete(model)()
        #expect(await eventually { model.settings.settings.map(\.name) == ["Default", "Setting 2"] })
        #expect(model.note == nil, "deleted here, not by a collaborator")
        model.choose(model.settings.settings[0].id)
        #expect(!model.canDelete)
        // A collaborator deletes the setting open here: the sheet hands over to the Default.
        let second = try #require(model.settings.settings.last?.id)
        model.choose(second)
        HTMLSetupSheet.option(model, \.fontMode, .fontMode).wrappedValue = .outlines
        try await flow.remote(DeleteHTMLSetting(second))
        #expect(model.selected == model.settings.settings[0].id && model.name == "Default" && model.note == "“Setting 2” was deleted by a collaborator.")
        #expect(model.draft.fontMode == .embed && model.edited.isEmpty)
        Render.view(HTMLSetupSheet(model: model))
        #expect(SheetKeys.escape(in: sheet), "Escape presses Cancel")
        #expect(await eventually { flow.nswindow.attachedSheet == nil })
    }

    @Test func aRangePublishesThosePagesAndAWarningShowsItsObject() async throws {
        let flow = try Flow()
        defer { flow.close() }
        _ = await flow.document.perform(AddPages(count: 2)).value
        await flow.document.settle()
        let pages = flow.document.pageList.pages
        #expect(pages.count == 3)
        // A bad link on page 2's rectangle.
        let rect = pages[1].rect
        let ids = await flow.document.addRectangles([Rect(x: rect.minX + 10, y: rect.minY + 10, width: 50, height: 50)])
        _ = await flow.document.perform(SetLink([ids[0].opID], url: "http://bad host")).value
        await flow.document.settle()
        let model = try #require(flow.features.presentPublish())
        let sheet = try #require(flow.sheet(WebFeatures.publishSheet))
        #expect(await eventually { flow.nswindow.attachedSheet === sheet })
        // Pages "2-3".
        model.range = "2-3"
        #expect(model.pages == [1, 2])
        #expect(SheetKeys.returnKey(in: sheet))
        #expect(await eventually { if case .done = model.phase { true } else { false } })
        let bundle = try #require(model.folder)
        let index = try #require(Self.contents(bundle)["index.html"].map { String(decoding: $0, as: UTF8.self) })
        #expect(index.contains("id=\"page-2\"") && index.contains("id=\"page-3\"") && !index.contains("id=\"page-1\""))
        // The warning names the rectangle; btn:[Show] selects it.
        let warning = try #require(model.visibleWarnings.first { $0.kind == .invalidLink })
        #expect(warning.node.map { OpID($0) } == ids[0].opID)
        flow.window.selection.model.clear()
        PublishSheet.show(model, warning)()
        #expect(flow.window.selection.selection.ids == ids)
        // A range that does not parse is refused with a note.
        model.range = "4"
        #expect(model.publish() == nil && model.phase == .failed("Enter pages to publish, such as 1-3, 5"))
    }

    @Test func theBrowserPopUpListsTheDefaultTheInstalledAndOther() async throws {
        let flow = try Flow()
        defer { flow.close() }
        let model = try #require(flow.features.presentPublish())
        #expect(model.browserChoice == .system && model.defaultBrowserName == "Safari")
        #expect(model.browserChoices.map(\.lastPathComponent) == ["Safari.app", "Firefox.app"])
        Render.view(BrowserPicker(choices: model.browserChoices, defaultName: model.defaultBrowserName, selection: PublishSheet.browser(model)))
        Render.view(BrowserPicker(choices: [], defaultName: nil, selection: .constant(.system)))
        // btn:[Other…]: an application picked in a panel on the sheet joins the list.
        let other = URL(filePath: "/Applications/Other Browser.app")
        let asked = TestBox<[NSWindow?]>([])
        flow.features.chooseApplication = { window in
            asked.value.append(window)
            return other
        }
        await model.chooseBrowser(.other)
        #expect(asked.value.count == 1 && asked.value[0] === flow.nswindow)
        #expect(model.browserChoice == .application(other) && model.browserChoices.last == other)
        #expect(flow.features.browser?.lastPathComponent == "Other Browser.app")
        // Cancelled: the choice stays; the default clears the preference.
        flow.features.chooseApplication = { _ in nil }
        await model.chooseBrowser(.other)
        #expect(model.browserChoice == .application(other))
        await model.chooseBrowser(.system)
        #expect(model.browserChoice == .system && flow.features.browser == nil)
        // The list itself: the default first, the rest by name, each once.
        let safari = URL(filePath: "/Applications/Safari.app"), arc = URL(filePath: "/Applications/Arc.app"), zen = URL(filePath: "/Applications/Zen.app")
        #expect(BrowserList.ordered([zen, safari, arc, zen], default: safari) == [safari, arc, zen])
        #expect(BrowserList.ordered([zen, arc], default: safari) == [arc, zen])
        #expect(BrowserList.ordered([zen], default: nil) == [zen])
        #expect(BrowserList.name(safari) == "Safari")
        // Launch Services' own lists answer on this Mac (the probe is a web address).
        let system = BrowserList()
        _ = system.installed()
        _ = system.defaultBrowser()
    }

    @Test func aRealFolderPanelGoesOnThePublishSheet() async throws {
        let flow = try Flow()
        defer { flow.close() }
        let sheet = try #require({ flow.features.presentPublish(); return flow.sheet(WebFeatures.publishSheet) }())
        #expect(await eventually { flow.nswindow.attachedSheet === sheet })
        // The app's own panel, not a stand-in: it must open on the sheet, where it can be seen.
        flow.features.chooseFolder = WebFeatures(preferences: flow.setup.environment.preferences).chooseFolder
        let answer = TestBox<URL??>(nil)
        let choose = flow.features.chooseFolder, parent = flow.nswindow
        Task { answer.value = .some(await choose(parent)) }
        let appeared = await eventually { sheet.attachedSheet != nil }
        #expect(appeared, "the folder panel is on the Publish sheet")
        #expect(flow.nswindow.attachedSheet === sheet, "and not queued behind it on the document window")
        if let panel = sheet.attachedSheet { sheet.endSheet(panel, returnCode: .cancel) }
        #expect(await eventually { answer.value != nil }, "cancelling the panel answers")
        #expect(answer.value == .some(nil))
    }
}

