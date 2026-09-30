import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTInterchange
import WTModel
import WTProto

/// One step of a publish: a page rendered, or a file of the bundle written.
enum HTMLPublishStep: Equatable, Sendable {
    case rendering(page: Int, of: Int)
    case writing(file: Int, of: Int)

    /// How far the publish is: rendering the pages is most of it.
    var fraction: Double {
        switch self {
        case let .rendering(page, total): 0.9 * Double(page) / Double(max(total, 1))
        case let .writing(file, total): 0.9 + 0.1 * Double(file) / Double(max(total, 1))
        }
    }

    var label: String {
        switch self {
        case let .rendering(page, total): "Page \(page) of \(total)"
        case let .writing(file, total): "Writing file \(file) of \(total)"
        }
    }
}

/// menu:File[Publish as HTML…] (WEB-009; publish-html.adoc, "Publishing"): the HTML setting, the
/// pages, the folder, *Show output warnings* and *Open when done* with its browser; publishing
/// runs off the main actor with the sheet's progress (page by page, then file by file) and
/// btn:[Cancel], which stops it between pages or files.  The bundle is assembled beside its folder
/// and swapped in only when complete (`HTMLBundle.install`), so a cancelled or failed publish
/// leaves the previous bundle, or no folder; then the folder is revealed, the page opened when
/// asked, and the warnings listed with btn:[Show].  A collaborator's change to the settings shows
/// in the open sheet.
@MainActor
@Observable
final class PublishModel {
    enum Phase: Equatable {
        case ready
        case publishing
        case done(URL)
        case failed(String)
    }

    @ObservationIgnored weak var window: DocumentWindowController?
    @ObservationIgnored let features: WebFeatures
    var selected: OpID?
    /// *Pages*: empty publishes every page; otherwise "1-3, 5".
    var range = ""
    var showWarnings = true
    var openWhenDone = false
    /// *Publish to*: a folder on this Mac or the document's web link (WEB-013).
    var destination = PublishDestination.folder
    /// Who can open the web link.
    var access = Wiretuner_Publish_V1_PublishAccess.members
    /// The web link's upload, its progress and the address.
    let webLink = WebLinkUpload()
    private(set) var phase = Phase.ready
    private(set) var warnings: [ExportWarning] = []
    /// The publish's latest step while it runs.
    private(set) var step: HTMLPublishStep?
    /// Whether btn:[Cancel] was clicked and the publish is stopping.
    private(set) var cancelling = false
    /// Bumped by every change to the document, so the sheet reads the settings again.
    private(set) var revision = 0
    /// The browsers the pop-up lists, read when the sheet opens.
    private(set) var browsers: [URL] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var observation: DocumentHandle.ObservationToken?
    @ObservationIgnored var onClose: @MainActor () -> Void = {}

    init(window: DocumentWindowController, features: WebFeatures) {
        self.window = window
        self.features = features
        selected = HTMLSettings(window.documentHandle.state).selected.id
        browsers = features.browsers.installed()
        observation = window.documentHandle.observe { [weak self] _ in self?.documentDidChange() }
    }

    /// The document changed (here or by a collaborator): the sheet reads the settings again.
    func documentDidChange() {
        revision += 1
        // The chosen setting was deleted (by a collaborator): the pop-up shows the one publishing uses.
        let settings = settings
        if settings.setting(selected) == nil { selected = settings.selected(selected).id }
    }

    /// The sheet went: stop following the document.
    func tearDown() {
        if let observation { window?.documentHandle.stopObserving(observation) }
        observation = nil
    }

    var settings: HTMLSettings {
        _ = revision
        return HTMLSettings(window?.documentHandle.state ?? EngineState())
    }
    var setting: HTMLSettingInfo { settings.selected(selected) }
    var pageCount: Int { window?.documentHandle.pageList.pages.count ?? 0 }

    /// The page indices `range` names (every page when empty); nil when it does not parse.
    static func pages(_ range: String, count: Int) -> [Int]? {
        let trimmed = range.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(0..<count) }
        var result: [Int] = []
        for part in trimmed.split(separator: ",") {
            let pieces = part.split(separator: "-", omittingEmptySubsequences: false)
            let bounds = pieces.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard bounds.count == pieces.count, bounds.count <= 2, bounds[0] >= 1, bounds[bounds.count - 1] >= bounds[0], bounds[bounds.count - 1] <= count else { return nil }
            result += (bounds[0] - 1)..<bounds[bounds.count - 1]
        }
        return result
    }

    var pages: [Int]? { Self.pages(range, count: pageCount) }

    /// Where the bundle goes: the setting's folder on this Mac, in a subfolder named after the
    /// document.
    var folder: URL? {
        guard let window, !setting.location.isEmpty else { return nil }
        return URL(filePath: setting.location).appending(path: window.documentHandle.title)
    }

    /// The pop-up's choice, remembered on this Mac.
    func select(_ id: OpID?) {
        selected = id
        window?.objectEditing.perform(SelectHTMLSetting(id))
    }

    /// btn:[Choose…]: the setting's folder on this Mac.
    func chooseFolder() async {
        guard let window, let url = await features.chooseFolder(window.window) else { return }
        features.remember(url)
        _ = await window.objectEditing.perform(SetHTMLSettingLocation(setting.id, to: url.path(percentEncoded: false))).value
    }

    // MARK: Browser

    /// The pop-up's choice: the *Preview browser* preference.
    var browserChoice: BrowserChoice {
        _ = revision
        return features.browser.map { .application($0) } ?? .system
    }

    /// The pop-up's items: the browsers installed, and the chosen one when it is not among them.
    var browserChoices: [URL] {
        guard case let .application(url) = browserChoice, !browsers.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return browsers }
        return browsers + [url]
    }

    /// The default browser's name for the pop-up's first item.
    var defaultBrowserName: String? { features.browsers.defaultBrowser().map(BrowserList.name) }

    /// A pop-up choice; btn:[Other…] asks for an application first.
    func chooseBrowser(_ choice: BrowserChoice) async {
        switch choice {
        case .system: features.browser = nil
        case let .application(url): features.browser = url
        case .other:
            guard let url = await features.chooseApplication(window?.window) else { break }
            features.browser = url
        }
        revision += 1
    }

    /// Whether the web link can be chosen now (it needs a connection; never queued).
    var webLinkAvailable: Bool { WebLinks.services?.isOnline ?? false }

    /// btn:[Publish].
    @discardableResult
    func publish() -> Task<Void, Never>? {
        if destination == .webLink { return publishToWebLink() }
        if folder == nil, window != nil, phase != .publishing {
            // No folder yet: ask for one, then publish into it.
            return Task { [weak self] in
                guard let self else { return }
                await self.chooseFolder()
                guard self.folder != nil else {
                    self.phase = .failed("Choose a folder to publish to")
                    return
                }
                await self.publish()?.value
            }
        }
        guard let window, let pages, !pages.isEmpty, let folder, phase != .publishing else {
            if pages?.isEmpty != false { phase = .failed("Enter pages to publish, such as 1-3, 5") }
            return nil
        }
        let settings = setting.settings
        let location = setting.location
        let scene: ExportScene
        do {
            scene = try features.scene(of: window, pages: pages)
        } catch {
            phase = .failed("The document could not be read for publishing: \(error.localizedDescription)")
            return nil
        }
        begin()
        let features = features
        let task = Task { [weak self] in
            let result = await features.withAccess(to: location) {
                await self?.run { report in
                    let bundle = try HTMLPublisher(settings: settings).publish(scene) { report(.rendering(page: $0, of: $1)) }
                    try bundle.install(at: folder) { report(.writing(file: $0, of: $1)) }
                    return bundle
                }
            }
            self?.finish(result, folder: folder)
        }
        self.task = task
        return task
    }

    /// A publish starts.
    private func begin() {
        phase = .publishing
        warnings = []
        step = nil
        cancelling = false
    }

    /// `work` run off the main actor, its steps shown in the sheet as they come; cancelling the
    /// calling task cancels it.
    private func run(_ work: @escaping @Sendable (_ report: @escaping @Sendable (HTMLPublishStep) -> Void) throws -> HTMLBundle) async -> Result<HTMLBundle, any Error> {
        guard !Task.isCancelled else { return .failure(CancellationError()) }
        let (steps, continuation) = AsyncStream.makeStream(of: HTMLPublishStep.self, bufferingPolicy: .bufferingNewest(1))
        let observe = features.observePublish
        let shown = Task { [weak self] in
            for await step in steps { self?.step = step }
        }
        let job = Task.detached(priority: .userInitiated) { () -> Result<HTMLBundle, any Error> in
            defer { continuation.finish() }
            return Result { try work { step in
                observe(step)
                continuation.yield(step)
            } }
        }
        let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        await shown.value
        return result
    }

    private func finish(_ result: Result<HTMLBundle, any Error>?, folder: URL) {
        defer { cancelling = false }
        do {
            guard let bundle = try result?.get() else { return }
            warnings = bundle.warnings.sorted
            phase = .done(folder)
            // Cancelled after the swap: the bundle is in place, but nothing opens.
            guard !cancelling else { return }
            features.reveal([folder])
            if openWhenDone { features.open(folder.appending(path: "index.html"), features.browser) }
        } catch is CancellationError {
            phase = .ready
        } catch {
            phase = .failed("The document could not be published: \(error.localizedDescription)")
        }
    }

    /// btn:[Publish] to the web link: the bundle built off the main actor, then uploaded; the
    /// address is shown and copied.  Cancelling stops between chunks; publishing again resumes.
    private func publishToWebLink() -> Task<Void, Never>? {
        guard let window, phase != .publishing else { return nil }
        guard let services = WebLinks.services, services.isOnline else {
            phase = .failed(WebLinks.unavailableReason == LocalMode.needsAccount
                ? "Publishing to a web link needs a WireTuner account" : "Publishing to a web link needs a connection")
            return nil
        }
        guard let pages, !pages.isEmpty else {
            phase = .failed("Enter pages to publish, such as 1-3, 5")
            return nil
        }
        let scene: ExportScene
        do {
            scene = try features.scene(of: window, pages: pages)
        } catch {
            phase = .failed("The document could not be read for publishing: \(error.localizedDescription)")
            return nil
        }
        begin()
        let settings = setting.settings
        let name = setting.displayName
        let access = access
        let document = window.documentHandle
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.run { report in
                try HTMLPublisher(settings: settings).publish(scene) { report(.rendering(page: $0, of: $1)) }
            }
            defer { self.cancelling = false }
            do {
                let bundle = try result.get()
                self.warnings = bundle.warnings.sorted
                let url = try await self.webLink.publish(WebLinks.files(bundle), document: document, settingName: name, access: access, services: services)
                // Registered even when btn:[Cancel] came too late to stop it: the link is published.
                self.phase = URL(string: url).map { .done($0) } ?? .ready
            } catch is CancellationError {
                self.phase = .ready
            } catch {
                self.phase = .failed("The document could not be published: \(error.localizedDescription)")
            }
        }
        self.task = task
        return task
    }

    /// btn:[Cancel] while publishing: the publish stops between pages or files and the folder
    /// keeps its previous bundle; otherwise btn:[Close].
    func cancel() {
        if phase == .publishing {
            cancelling = true
            task?.cancel()
        } else {
            onClose()
        }
    }

    /// A warning's btn:[Show]: selects the object on the canvas.
    func show(_ warning: ExportWarning) {
        guard let window, let node = warning.node else { return }
        let id = SelectionID(OpID(node))
        window.selection.model.apply([id], mode: .replace)
        window.fit(selection: window.selection.selectedBounds)
    }

    var visibleWarnings: [ExportWarning] { showWarnings ? warnings : [] }
}

/// Where btn:[Publish] writes.
enum PublishDestination: Hashable {
    case folder
    case webLink
}

struct PublishSheet: View {
    @Bindable var model: PublishModel

    static func publish(_ model: PublishModel) -> () -> Void { { model.publish() } }
    static func cancel(_ model: PublishModel) -> () -> Void { { model.cancel() } }
    static func choose(_ model: PublishModel) -> () -> Void { { Task { await model.chooseFolder() } } }
    static func setup(_ model: PublishModel) -> () -> Void { { model.features.presentSetup() } }
    static func show(_ model: PublishModel, _ warning: ExportWarning) -> () -> Void { { model.show(warning) } }
    static func selection(_ model: PublishModel) -> Binding<OpID?> {
        Binding(get: { model.selected }, set: { model.select($0) })
    }
    static func browser(_ model: PublishModel) -> Binding<BrowserChoice> {
        Binding(get: { model.browserChoice }, set: { choice in Task { await model.chooseBrowser(choice) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("HTML setting", selection: Self.selection(model)) {
                    ForEach(model.settings.settings, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                Button("Setup…", action: Self.setup(model))
            }
            HStack {
                Text("Pages")
                TextField("All", text: $model.range).frame(width: 120).accessibilityIdentifier("publish.pages")
                Text("of \(model.pageCount)").foregroundStyle(.secondary)
            }
            Picker("Publish to", selection: $model.destination) {
                Text("Folder on this Mac").tag(PublishDestination.folder)
                Text(model.webLinkAvailable ? "Web link" : "Web link (\(WebLinks.unavailableReason))").tag(PublishDestination.webLink)
                    .selectionDisabled(!model.webLinkAvailable)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("publish.destination")
            if model.destination == .folder {
                HStack {
                    Text(model.folder?.path(percentEncoded: false) ?? "No folder chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…", action: Self.choose(model))
                }
            } else {
                Picker("Who can open it", selection: $model.access) {
                    Text(WebLinks.title(.members)).tag(Wiretuner_Publish_V1_PublishAccess.members)
                    Text(WebLinks.title(.anyoneWithLink)).tag(Wiretuner_Publish_V1_PublishAccess.anyoneWithLink)
                }
                .accessibilityIdentifier("publish.access")
                if let url = model.webLink.url {
                    Text("\(url) (copied)").font(.caption).textSelection(.enabled).accessibilityIdentifier("publish.url")
                }
            }
            Toggle("Show output warnings", isOn: $model.showWarnings)
            HStack {
                Toggle("Open when done", isOn: $model.openWhenDone)
                BrowserPicker(choices: model.browserChoices, defaultName: model.defaultBrowserName, selection: Self.browser(model))
                    .disabled(!model.openWhenDone)
            }
            switch model.phase {
            case .ready: EmptyView()
            case .publishing:
                if model.cancelling {
                    ProgressView("Cancelling…").controlSize(.small)
                } else if model.destination == .webLink, let progress = model.webLink.progress {
                    ProgressView(value: progress.fraction) { Text(WebLinkUpload.label(progress)) }.controlSize(.small)
                } else if let step = model.step {
                    ProgressView(value: step.fraction) { Text(step.label) }.controlSize(.small).accessibilityIdentifier("publish.progress")
                } else {
                    ProgressView("Publishing…").controlSize(.small)
                }
            case .done(let folder):
                Text(folder.isFileURL ? "Published to \(folder.lastPathComponent)" : "Published to the web link").foregroundStyle(.secondary)
            case .failed(let message): Text(message).foregroundStyle(.red)
            }
            ForEach(Array(model.visibleWarnings.enumerated()), id: \.offset) { _, warning in
                HStack {
                    Text(warning.message).font(.caption).lineLimit(2)
                    Spacer()
                    if warning.node != nil { Button("Show", action: Self.show(model, warning)).controlSize(.small) }
                }
            }
            HStack {
                Button("Published Links…") { model.features.presentPublishedLinks() }.accessibilityIdentifier("publish.links")
                Spacer()
                Button(model.phase == .publishing ? "Cancel" : "Close", action: Self.cancel(model)).keyboardShortcut(.cancelAction)
                    .disabled(model.cancelling).accessibilityIdentifier("publish.cancel")
                Button("Publish", action: Self.publish(model)).keyboardShortcut(.defaultAction).disabled(model.phase == .publishing)
                    .accessibilityIdentifier("publish.publish")
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

/// The HTML Setup sheet (WEB-009; publish-html.adoc, "HTML settings"): the settings list with
/// btn:[+] and btn:[−] (*Default* cannot be deleted), and every option of the selected setting;
/// btn:[Apply] writes the edited options (one change), btn:[OK] applies and closes.  A change to
/// the settings -- a collaborator's, or this Mac's from the Publish sheet -- shows in the open
/// sheet as it arrives: the list, the location, and every field not edited here (the field being
/// edited keeps what was typed).  The chosen setting deleted by a collaborator hands over to the
/// first, with a note.
@MainActor
@Observable
final class HTMLSetupModel {
    @ObservationIgnored weak var window: DocumentWindowController?
    @ObservationIgnored let features: WebFeatures
    private(set) var selected: OpID?
    var name = ""
    var draft = HTMLPublishSettings.defaults
    /// The options edited since the setting was chosen.
    private(set) var edited: Set<HTMLSettingOption> = []
    /// Whether the name has been edited since the setting was chosen.
    private(set) var nameEdited = false
    /// Why the sheet changed setting under the person (the one chosen was deleted).
    private(set) var note: String?
    /// Bumped by every change to the document, so the sheet reads the settings again.
    private(set) var revision = 0
    @ObservationIgnored private var observation: DocumentHandle.ObservationToken?
    @ObservationIgnored var onClose: @MainActor () -> Void = {}

    init(window: DocumentWindowController, features: WebFeatures) {
        self.window = window
        self.features = features
        choose(HTMLSettings(window.documentHandle.state).selected.id)
        observation = window.documentHandle.observe { [weak self] _ in self?.documentDidChange() }
    }

    /// The sheet went: stop following the document.
    func tearDown() {
        if let observation { window?.documentHandle.stopObserving(observation) }
        observation = nil
    }

    /// The document changed: the list and the fields not edited here follow it.
    func documentDidChange() {
        revision += 1
        let settings = settings
        if selected == nil, let first = settings.settings.first?.id {
            // The synthesized Default was materialized (here or elsewhere): follow its element.
            selected = first
        }
        guard settings.setting(selected) != nil else {
            let gone = name
            choose(settings.settings.first?.id)
            note = "“\(gone)” was deleted by a collaborator."
            return
        }
        refresh()
    }

    var settings: HTMLSettings {
        _ = revision
        return HTMLSettings(window?.documentHandle.state ?? EngineState())
    }
    var setting: HTMLSettingInfo? { settings.setting(selected) }
    /// The first setting (the Default) cannot be deleted.
    var canDelete: Bool { selected != nil && settings.settings.first?.id != selected }

    func choose(_ id: OpID?) {
        selected = id
        let info = settings.setting(id) ?? settings.settings[0]
        name = info.name
        draft = info.settings
        edited = []
        nameEdited = false
        note = nil
    }

    /// The name field, typed.
    func rename(_ name: String) {
        self.name = name
        nameEdited = true
    }

    /// An option edited here.
    func set<Value>(_ keyPath: WritableKeyPath<HTMLPublishSettings, Value>, _ value: Value, option: HTMLSettingOption) {
        draft[keyPath: keyPath] = value
        edited.insert(option)
    }

    /// A remote change arrived: options not edited here follow the stored setting.
    func refresh() {
        guard let info = setting else { return }
        if !nameEdited { name = info.name }
        var merged = info.settings
        let draft = draft
        for option in edited {
            switch option {
            case .layout: merged.layout = draft.layout
            case .pageMode: merged.pageMode = draft.pageMode
            case .vectorFormat: merged.vectorFormat = draft.vectorFormat
            case .scale: merged.scale = draft.scale
            case .imageFormat: merged.imageFormat = draft.imageFormat
            case .imageQuality: merged.imageQuality = draft.imageQuality
            case .fontMode: merged.fontMode = draft.fontMode
            case .animationStill: merged.animationStill = draft.animationStill
            case .svgAnimationPosterOnly: merged.svgAnimationPosterOnly = draft.svgAnimationPosterOnly
            case .background: merged.background = draft.background
            case .title: merged.title = draft.title
            case .allowScripts: merged.allowScripts = draft.allowScripts
            }
        }
        self.draft = merged
    }

    /// btn:[+]: a new setting with the Default's options.
    @discardableResult
    func add() async -> OpID? {
        guard let window else { return nil }
        let count = settings.settings.count
        _ = await window.objectEditing.perform(AddHTMLSetting(name: "Setting \(count + 1)")).value
        let added = settings.settings.last?.id
        choose(added)
        return added
    }

    /// btn:[−].
    @discardableResult
    func delete() async -> Bool {
        guard let window, canDelete, let selected else { return false }
        // The first setting is chosen before the delete lands, so the sheet does not read it as a
        // collaborator's.
        choose(settings.settings.first?.id)
        let change = await window.objectEditing.perform(DeleteHTMLSetting(selected)).value
        return change != nil
    }

    /// btn:[Apply]: the name and the edited options.
    @discardableResult
    func apply() async -> Bool {
        guard let window else { return false }
        var wrote = false
        if let info = setting, name != info.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            wrote = await window.objectEditing.perform(RenameHTMLSetting(selected, to: name)).value != nil
            // Renaming the synthesized Default materialized it: later edits go to that element.
            if selected == nil { selected = settings.settings.first?.id }
        }
        nameEdited = false
        if !edited.isEmpty {
            if await window.objectEditing.perform(EditHTMLSetting(selected, settings: draft, options: edited)).value != nil { wrote = true }
            if selected == nil { selected = settings.settings.first?.id }
            edited = []
        }
        return wrote
    }

    /// btn:[OK].
    func confirm() async {
        await apply()
        onClose()
    }

    /// btn:[Choose…] for *Location*.
    func chooseLocation() async {
        guard let window, let url = await features.chooseFolder(window.window) else { return }
        features.remember(url)
        _ = await window.objectEditing.perform(SetHTMLSettingLocation(selected, to: url.path(percentEncoded: false))).value
    }
}

struct HTMLSetupSheet: View {
    let model: HTMLSetupModel

    static func add(_ model: HTMLSetupModel) -> () -> Void { { Task { await model.add() } } }
    static func delete(_ model: HTMLSetupModel) -> () -> Void { { Task { await model.delete() } } }
    static func apply(_ model: HTMLSetupModel) -> () -> Void { { Task { await model.apply() } } }
    static func confirm(_ model: HTMLSetupModel) -> () -> Void { { Task { await model.confirm() } } }
    static func cancel(_ model: HTMLSetupModel) -> () -> Void { { model.onClose() } }
    static func location(_ model: HTMLSetupModel) -> () -> Void { { Task { await model.chooseLocation() } } }
    static func selection(_ model: HTMLSetupModel) -> Binding<OpID?> {
        Binding(get: { model.selected }, set: { model.choose($0) })
    }
    static func option<Value>(_ model: HTMLSetupModel, _ keyPath: WritableKeyPath<HTMLPublishSettings, Value>, _ option: HTMLSettingOption) -> Binding<Value> {
        Binding(get: { model.draft[keyPath: keyPath] }, set: { model.set(keyPath, $0, option: option) })
    }
    static func name(_ model: HTMLSetupModel) -> Binding<String> {
        Binding(get: { model.name }, set: { model.rename($0) })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading) {
                List(model.settings.settings, id: \.id, selection: Self.selection(model)) { setting in
                    Text(setting.displayName).tag(setting.id)
                }
                .frame(width: 160, height: 260)
                HStack {
                    Button("+", action: Self.add(model)).accessibilityIdentifier("setup.add")
                    Button("−", action: Self.delete(model)).disabled(!model.canDelete).accessibilityIdentifier("setup.delete")
                }
            }
            Form {
                if let note = model.note { Text(note).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("setup.note") }
                TextField("Name", text: Self.name(model)).accessibilityIdentifier("setup.name")
                LabeledContent("Location") {
                    HStack {
                        Text(model.setting?.location.isEmpty == false ? model.setting!.location : "None").lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: Self.location(model))
                    }
                }
                Picker("Layout", selection: Self.option(model, \.layout, .layout)) {
                    Text("Whole pages").tag(HTMLLayout.wholePages)
                    Text("Positioned objects").tag(HTMLLayout.positionedObjects)
                }
                Picker("Pages", selection: Self.option(model, \.pageMode, .pageMode)) {
                    Text("Stacked in one file").tag(HTMLPageMode.stacked)
                    Text("Separate files").tag(HTMLPageMode.separateFiles)
                }
                Picker("Vector art", selection: Self.option(model, \.vectorFormat, .vectorFormat)) {
                    Text("SVG").tag(HTMLVectorFormat.svg)
                    Text("PNG").tag(HTMLVectorFormat.png)
                }
                Picker("Scale", selection: Self.option(model, \.scale, .scale)) {
                    ForEach(1...3, id: \.self) { Text("\($0)×").tag($0) }
                }
                Picker("Images", selection: Self.option(model, \.imageFormat, .imageFormat)) {
                    Text("JPEG").tag(HTMLImageFormat.jpeg)
                    Text("PNG").tag(HTMLImageFormat.png)
                    Text("WebP").tag(HTMLImageFormat.webp)
                }
                Stepper("Quality \(model.draft.imageQuality)", value: Self.option(model, \.imageQuality, .imageQuality), in: 1...100)
                Picker("Fonts", selection: Self.option(model, \.fontMode, .fontMode)) {
                    Text("Embed").tag(HTMLFontMode.embed)
                    Text("Convert to outlines").tag(HTMLFontMode.outlines)
                    Text("System fonts").tag(HTMLFontMode.system)
                }
                Toggle("Animation: still", isOn: Self.option(model, \.animationStill, .animationStill))
                Toggle("SVG animations: poster only", isOn: Self.option(model, \.svgAnimationPosterOnly, .svgAnimationPosterOnly))
                Toggle("Allow scripts", isOn: Self.option(model, \.allowScripts, .allowScripts))
                Picker("Page background", selection: Self.option(model, \.background, .background)) {
                    Text("Document").tag(HTMLBackground.document)
                    Text("White").tag(HTMLBackground.white)
                    Text("Transparent").tag(HTMLBackground.transparent)
                }
                TextField("Title", text: Self.option(model, \.title, .title))
                HStack {
                    Spacer()
                    Button("Cancel", action: Self.cancel(model)).keyboardShortcut(.cancelAction)
                    Button("Apply", action: Self.apply(model))
                    Button("OK", action: Self.confirm(model)).keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 360)
        }
        .padding(16)
    }
}
