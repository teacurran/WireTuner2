import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTInterchange
import WTModel
import WTProto

/// menu:File[Publish as HTML…] (WEB-009; publish-html.adoc, "Publishing"): the HTML setting, the
/// pages, the folder, *Show output warnings* and *Open when done*; publishing runs off the main
/// actor with the sheet's progress and btn:[Cancel] (nothing is written until the bundle is
/// built, so a cancelled publish leaves no folder), then the folder is revealed, the page opened
/// when asked, and the warnings listed with btn:[Show].
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
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onClose: @MainActor () -> Void = {}

    init(window: DocumentWindowController, features: WebFeatures) {
        self.window = window
        self.features = features
        selected = HTMLSettings(window.documentHandle.state).selected.id
    }

    var settings: HTMLSettings { HTMLSettings(window?.documentHandle.state ?? EngineState()) }
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
        phase = .publishing
        warnings = []
        let settings = setting.settings
        let scene: ExportScene
        do {
            scene = try features.scene(of: window, pages: pages)
        } catch {
            phase = .failed("The document could not be read for publishing: \(error.localizedDescription)")
            return nil
        }
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<HTMLBundle, any Error> in
                Result { try HTMLPublisher(settings: settings).publish(scene) }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.finish(result, folder: folder)
        }
        self.task = task
        return task
    }

    private func finish(_ result: Result<HTMLBundle, any Error>, folder: URL) {
        do {
            let bundle = try result.get()
            try features.withAccess(to: setting.location) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                _ = try bundle.write(to: folder)
            }
            warnings = bundle.warnings.sorted
            phase = .done(folder)
            features.reveal([folder])
            if openWhenDone { features.open(folder.appending(path: "index.html")) }
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
        phase = .publishing
        warnings = []
        let settings = setting.settings
        let name = setting.displayName
        let access = access
        let document = window.documentHandle
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<HTMLBundle, any Error> in
                Result { try HTMLPublisher(settings: settings).publish(scene) }
            }.value
            guard let self, !Task.isCancelled else { return }
            do {
                let bundle = try result.get()
                self.warnings = bundle.warnings.sorted
                let url = try await self.webLink.publish(WebLinks.files(bundle), document: document, settingName: name, access: access, services: services)
                guard !Task.isCancelled else { return }
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

    /// btn:[Cancel] while publishing: nothing is written.
    func cancel() {
        if phase == .publishing {
            task?.cancel()
            task = nil
            phase = .ready
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
            Toggle("Open when done", isOn: $model.openWhenDone)
            switch model.phase {
            case .ready: EmptyView()
            case .publishing:
                if model.destination == .webLink, let progress = model.webLink.progress {
                    ProgressView(value: progress.fraction) { Text(WebLinkUpload.label(progress)) }.controlSize(.small)
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
/// btn:[Apply] writes the edited options (one change), btn:[OK] applies and closes.  A remote
/// change to the setting shows in the sheet unless the field has been edited here.
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
    @ObservationIgnored var onClose: @MainActor () -> Void = {}

    init(window: DocumentWindowController, features: WebFeatures) {
        self.window = window
        self.features = features
        choose(HTMLSettings(window.documentHandle.state).selected.id)
    }

    var settings: HTMLSettings { HTMLSettings(window?.documentHandle.state ?? EngineState()) }
    var setting: HTMLSettingInfo? { settings.setting(selected) }
    /// The first setting (the Default) cannot be deleted.
    var canDelete: Bool { selected != nil && settings.settings.first?.id != selected }

    func choose(_ id: OpID?) {
        selected = id
        let info = settings.setting(id) ?? settings.settings[0]
        name = info.name
        draft = info.settings
        edited = []
    }

    /// An option edited here.
    func set<Value>(_ keyPath: WritableKeyPath<HTMLPublishSettings, Value>, _ value: Value, option: HTMLSettingOption) {
        draft[keyPath: keyPath] = value
        edited.insert(option)
    }

    /// A remote change arrived: options not edited here follow the stored setting.
    func refresh() {
        guard let info = setting else { return }
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
        let change = await window.objectEditing.perform(DeleteHTMLSetting(selected)).value
        choose(settings.settings.first?.id)
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
        Binding(get: { model.name }, set: { model.name = $0 })
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
                TextField("Name", text: Self.name(model))
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
