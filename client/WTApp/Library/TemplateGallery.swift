import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTRender
import WTSync

/// Where a library template's content comes from when a document is made from it
/// (templates.adoc, "Offline behavior"): the window it is open in, else its local store, else the
/// server at head, cached on this Mac the first time (`TemplateDownload`).
@MainActor
struct TemplateStates {
    /// The state of a template open in a window.
    var open: @MainActor (String) -> EngineState? = { _ in nil }
    /// Whether this Mac has the template's store.
    var isCached: @MainActor (String) -> Bool = { _ in false }
    /// The state from its store, else fetched and cached; throws offline for an uncached template.
    var load: @MainActor (String) async throws -> EngineState = { _ in throw TemplateDownload.Failure.notCached }

    func state(of id: String) async throws -> EngineState {
        if let state = open(id) { return state }
        return try await load(id)
    }

    /// Whether a document can be made from `id` without a connection.
    func isAvailableOffline(_ id: String) -> Bool {
        open(id) != nil || isCached(id)
    }
}

/// menu:File[New from Template…]'s gallery (templates.adoc; DOC-029): the six starting points with
/// their side-panel options, *My templates* and each team's templates from the library, and
/// btn:[Create].  An uncached template is dimmed offline with the reason.
@MainActor
@Observable
final class TemplateGalleryModel {
    enum Choice: Hashable {
        case startingPoint(StartingPoints.Kind)
        case template(String)
    }

    static let offlineUncached = "Not on this Mac yet. Connect to the internet to use this template."
    static let myTemplates = "My Templates"
    /// The side panel's units.
    static let units: [LengthUnit] = [.points, .picas, .inches, .millimeters, .pixels]
    /// The side panel's sizes: the standard presets, then Custom.
    static let presets: [PagePreset] = PagePreset.standard

    @ObservationIgnored let library: LibraryModel
    @ObservationIgnored var states: TemplateStates
    /// Closes the gallery's window.
    @ObservationIgnored var onClose: @MainActor () -> Void = {}

    var choice: Choice = .startingPoint(.blank) {
        didSet {
            if case let .startingPoint(kind) = choice, kind != options.kind { options = StartingPoints.defaults(for: kind) }
            errorMessage = nil
        }
    }

    var options = StartingPoints.defaults(for: .blank)
    private(set) var isCreating = false
    private(set) var errorMessage: String?

    init(library: LibraryModel, states: TemplateStates = TemplateStates()) {
        self.library = library
        self.states = states
    }

    /// *My Templates*, then each team's, those with none left out.
    var groups: [(title: String, templates: [LibraryDocument])] {
        library.templateGroups.compactMap { group in
            group.templates.isEmpty ? nil : (group.space.kind == .personal ? Self.myTemplates : group.space.name, group.templates)
        }
    }

    /// Why `template` cannot be used now; nil when it can.
    func unavailableReason(_ template: LibraryDocument) -> String? {
        library.isOnline || states.isAvailableOffline(template.id) ? nil : Self.offlineUncached
    }

    var canCreate: Bool {
        guard !isCreating else { return false }
        switch choice {
        case .startingPoint: return options.geometry.isValid && (1...StartingPoints.maximumPageCount).contains(options.pageCount)
        case let .template(id): return library.cache.documents[id].map { unavailableReason($0) == nil } ?? false
        }
    }

    /// The size pop-up's selection: a preset's name, or "" for Custom.
    var presetName: String {
        get { options.preset }
        set {
            options.preset = newValue
            if let preset = Self.presets.first(where: { $0.name == newValue }) { options.size = Size(width: preset.width, height: preset.height) }
        }
    }

    /// The width and height fields, in points as oriented.
    var width: Double {
        get { options.geometry.width }
        set { setSize(width: newValue, height: options.geometry.height) }
    }

    var height: Double {
        get { options.geometry.height }
        set { setSize(width: options.geometry.width, height: newValue) }
    }

    private func setSize(width: Double, height: Double) {
        options.preset = ""
        options.orientation = height >= width ? .portrait : .landscape
        options.size = Size(width: min(width, height), height: max(width, height))
    }

    /// btn:[Create]: an untitled document from the choice, opened in a new tab; the gallery
    /// closes.  A template's content is fetched first (cached from then on).
    @discardableResult
    func create() async -> LibraryDocument? {
        guard canCreate else { return nil }
        isCreating = true
        defer { isCreating = false }
        let template: DocumentCreation.Template
        switch choice {
        case .startingPoint:
            template = .startingPoint(options)
        case let .template(id):
            do {
                template = .document(try await states.state(of: id), name: library.cache.documents[id]?.name ?? "")
            } catch {
                errorMessage = LibraryConnectivity.isOffline(error) || error as? TemplateDownload.Failure == .notCached
                    ? Self.offlineUncached : "The template could not be opened: \(LibraryModel.message(for: error) ?? "\(error)")"
                return nil
            }
        }
        let document = library.createDocument(template: template)
        onClose()
        return document
    }
}

/// The gallery's content.
struct TemplateGalleryView: View {
    @Bindable var model: TemplateGalleryModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Starting Points").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(StartingPoints.Kind.allCases) { kind in
                            tile(title: kind.title, subtitle: kind.summary, image: nil, symbol: Self.symbol(kind), choice: .startingPoint(kind), reason: nil)
                                .accessibilityIdentifier("gallery.start.\(kind.rawValue)")
                        }
                    }
                    ForEach(model.groups, id: \.title) { group in
                        Text(group.title).font(.headline).padding(.top, 8)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], alignment: .leading, spacing: 12) {
                            ForEach(group.templates) { template in
                                tile(title: template.name, subtitle: nil, image: model.library.thumbnailImage(for: template), symbol: "doc.on.doc",
                                     choice: .template(template.id), reason: model.unavailableReason(template))
                                    .accessibilityIdentifier("gallery.template.\(template.id)")
                            }
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            TemplateGalleryPanel(model: model)
                .frame(width: 240)
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    static func symbol(_ kind: StartingPoints.Kind) -> String {
        switch kind {
        case .blank: "doc"
        case .print: "printer"
        case .screen: "display"
        case .stationery: "envelope"
        case .publication: "book"
        case .technical: "ruler"
        }
    }

    private func tile(title: String, subtitle: String?, image: NSImage?, symbol: String, choice: TemplateGalleryModel.Choice, reason: String?) -> some View {
        let selected = model.choice == choice
        return VStack(alignment: .leading, spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(4)
                } else {
                    Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 90)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 3 : 1))
            Text(title).lineLimit(1)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .opacity(reason == nil ? 1 : 0.4)
        .help(reason ?? "")
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.choice = choice
            Task { await model.create() }
        }
        .onTapGesture { model.choice = choice }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The side panel: a starting point's options, or a template's name; btn:[Create].
struct TemplateGalleryPanel: View {
    @Bindable var model: TemplateGalleryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.choice {
            case let .startingPoint(kind):
                Text(kind.title).font(.headline)
                Text(kind.summary).font(.caption).foregroundStyle(.secondary)
                Form {
                    Picker("Size", selection: $model.presetName) {
                        ForEach(TemplateGalleryModel.presets, id: \.name) { Text($0.name).tag($0.name) }
                        Text("Custom").tag("")
                    }
                    .accessibilityIdentifier("gallery.size")
                    TextField("Width", value: $model.width, format: .number).accessibilityIdentifier("gallery.width")
                    TextField("Height", value: $model.height, format: .number).accessibilityIdentifier("gallery.height")
                    Picker("Orientation", selection: $model.options.orientation) {
                        Text("Portrait").tag(PageGeometry.Orientation.portrait)
                        Text("Landscape").tag(PageGeometry.Orientation.landscape)
                    }
                    Picker("Units", selection: $model.options.units) {
                        ForEach(TemplateGalleryModel.units, id: \.self) { Text($0.name.capitalized).tag($0) }
                    }
                    .accessibilityIdentifier("gallery.units")
                    Picker("Color mode", selection: $model.options.colorMode) {
                        ForEach(StartingPoints.ColorMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if kind == .publication {
                        Stepper("Pages: \(model.options.pageCount)", value: $model.options.pageCount, in: 1...StartingPoints.maximumPageCount)
                            .accessibilityIdentifier("gallery.pages")
                    }
                }
            case let .template(id):
                Text(model.library.cache.documents[id]?.name ?? "").font(.headline)
                Text("A new untitled copy; the template is not changed.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("gallery.error")
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { Task { await model.create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCreate)
                    .accessibilityIdentifier("gallery.create")
            }
        }
        .padding(16)
    }
}

/// The gallery's window: one per app, opened by menu:File[New from Template…], the Library's
/// btn:[New from Template…] and, with *Show the gallery at launch*, at launch.
@MainActor
final class TemplateGalleryWindowController: NSWindowController, NSWindowDelegate {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("template-gallery")

    let model: TemplateGalleryModel

    init(model: TemplateGalleryModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = "New from Template"
        window.identifier = Self.windowIdentifier
        window.setAccessibilityIdentifier(Self.windowIdentifier.rawValue)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: TemplateGalleryView(model: model))
        window.center()
        super.init(window: window)
        window.delegate = self
        model.onClose = { [weak window] in window?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TemplateGalleryWindowController is built in code")
    }

    /// Brings the gallery forward and lists the library's templates.
    @discardableResult
    func show() -> Task<Void, Never> {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        let library = model.library
        return Task { await library.refreshTemplates() }
    }
}
