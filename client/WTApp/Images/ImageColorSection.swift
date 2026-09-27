import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTModel
import WTRender

/// The Object panel's *Image* colour rows (image-color.adoc, "Setting an image's source profile";
/// CMS-013): *Type* (the colour model and whether the file carries a profile), *Source profile*
/// (Embedded, Document default, the bundled and installed profiles of the model, *Other…*) and
/// *Intent*.  With several images selected a row reads *Mixed* until a choice applies to all of
/// them; every choice is one change.  Values are read from the document on every render, so a
/// remote assignment shows at once.
@MainActor
struct ImageColorSectionModel {
    let panel: ObjectPanelModel
    let images: [(id: OpID, info: ImageColorInfo)]
    let registry: WTColor.ProfileRegistry

    init?(_ panel: ObjectPanelModel, registry: WTColor.ProfileRegistry = .shared) {
        let state = panel.document.state
        let images = panel.objects.compactMap { object in ImageColorInfo(object.id, in: state, registry: registry).map { (object.id, $0) } }
        guard !images.isEmpty, images.count == panel.objects.count else { return nil }
        self.panel = panel
        self.images = images
        self.registry = registry
    }

    var nodes: [OpID] { images.map(\.id) }

    static func modelName(_ mode: ImageMode) -> String {
        switch mode {
        case .cmyk: "CMYK"
        case .grayscale: "Grayscale"
        case .bilevel: "Bitmap"
        case .indexed: "Indexed"
        case .rgb: "RGB"
        }
    }

    /// "RGB, embedded profile: sRGB IEC61966-2.1", "CMYK, no embedded profile", or "Mixed".
    var type: String {
        shared(images.map { image in
            "\(Self.modelName(image.info.mode)), " + (image.info.embedded.map { "embedded profile: \($0.name)" } ?? "no embedded profile")
        }) ?? "Mixed"
    }

    /// The images' shared profile space; nil when they differ (only Embedded and Document default
    /// are offered then).
    var space: WTColor.ProfileSpace? { shared(images.map(\.info.space)) }

    static func id(_ choice: ImageSourceChoice) -> String {
        switch choice {
        case .embedded: "embedded"
        case .documentDefault: "default"
        case .profile(let profile): profile.isBundled ? "bundled:\(profile.bundledID)" : "hash:\(profile.hexHash)"
        }
    }

    static let mixed = "mixed"
    static let other = "other"

    /// What the menu shows now.
    var selection: String { shared(images.map { Self.id($0.info.source) }) ?? Self.mixed }

    /// One menu item.
    struct Choice: Hashable {
        enum Source: Hashable {
            case choice(ImageSourceChoice)
            case file(URL)
        }

        var id: String
        var title: String
        var source: Source
    }

    /// The menu: Embedded (when every image carries a profile), Document default, then the bundled,
    /// assigned and installed profiles of the images' model.
    func choices(installed: [InstalledProfileFile]) -> [Choice] {
        var result: [Choice] = []
        let embedded = images.compactMap(\.info.embedded)
        if embedded.count == images.count {
            let name = shared(embedded.map(\.name)).map { "Embedded: \($0)" } ?? "Embedded"
            result.append(Choice(id: "embedded", title: name, source: .choice(.embedded)))
        }
        result.append(Choice(id: "default", title: "Document default", source: .choice(.documentDefault)))
        guard let space else { return result }
        let assigned = images.compactMap { image -> WTColor.ProfileRef? in
            if case .profile(let profile) = image.info.source { return profile }
            return nil
        }
        // The document's profiles (*In this document*, CMS-010) after the bundled and assigned ones.
        let carried = ColorSettings.documentProfiles(panel.document.state, space: space)
        for profile in registry.bundledProfiles.filter({ $0.space == space }) + assigned + carried where profile.space == space {
            let choice = Choice(id: Self.id(.profile(profile)), title: profile.name, source: .choice(.profile(profile)))
            if !result.contains(where: { $0.id == choice.id }) { result.append(choice) }
        }
        for profile in installed where profile.space == space {
            result.append(Choice(id: "file:\(profile.url.path)", title: profile.name, source: .file(profile.url)))
        }
        return result
    }

    /// The *Intent* menu: *Document* (nil) and the four intents.
    static let intents: [(WTColor.RenderingIntent?, String)] = [
        (nil, "Document"), (.perceptual, "Perceptual"), (.relativeColorimetric, "Relative colorimetric"), (.saturation, "Saturation"),
        (.absoluteColorimetric, "Absolute colorimetric"),
    ]

    static func intentID(_ intent: WTColor.RenderingIntent?) -> String { intents.first { $0.0 == intent }?.1 ?? "Document" }

    var intent: String { shared(images.map { Self.intentID($0.info.intent) }) ?? Self.mixed }

    func setIntent(_ id: String) -> (any WTModel.Command)? {
        guard let entry = Self.intents.first(where: { $0.1 == id }) else { return nil }
        return SetImageIntent(nodes, intent: entry.0)
    }

    func assign(_ choice: ImageSourceChoice) -> any WTModel.Command {
        SetImageSourceProfile(nodes, choice)
    }

    /// Loads a profile file (an installed one, or *Other…*'s) and assigns it.
    @discardableResult
    func assign(file url: URL) -> Task<Void, Never> {
        let load = ImageColorSection.loadProfile(panel.document)
        let panel = panel, nodes = nodes
        return Task { @MainActor in
            guard let profile = try? await load(url) else { return }
            panel.perform(SetImageSourceProfile(nodes, .profile(profile)))
        }
    }
}

/// An installed profile file the menu offers.
struct InstalledProfileFile: Hashable {
    var name: String
    var url: URL
    var space: WTColor.ProfileSpace
}

/// The rows and their registration.
@MainActor
enum ImageColorSection {
    /// *Other…*'s open panel; replaceable in tests.
    static var chooseFile: @MainActor () async -> URL? = {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]
        panel.message = "Choose a profile for the selected images"
        return await panel.begin() == .OK ? panel.url : nil
    }

    /// Loads a profile file for `document`: through the shared blob cache when the app has one (so
    /// collaborators get it), else registered in this process.
    static var loadProfile: @MainActor (DocumentHandle) -> @MainActor (URL) async throws -> WTColor.ProfileRef = { document in
        if let glue = ProfileBlobGlue.shared { return glue.loader(for: document) }
        return { url in
            guard let ref = WTColor.ProfileRegistry.shared.register(iccData: try Data(contentsOf: url)) else { throw CocoaError(.fileReadCorruptFile) }
            return ref
        }
    }

    /// The installed profiles, read when the menu is built.
    static var installed: @MainActor () -> [InstalledProfileFile] = {
        WTColor.ProfileRegistry.shared.installedProfiles().map { InstalledProfileFile(name: $0.name, url: $0.url, space: $0.space) }
    }

    static func register(into registry: InspectorRegistry) {
        registry.register(InspectorSection(id: "imageColor", order: 73, kinds: [.image]) { panel in
            ImageColorSectionModel(panel).map { AnyView(ImageColorSectionView(model: $0)) }
        })
    }

    /// The menu's binding: a choice assigns, *Other…* asks for a file.
    static func source(_ model: ImageColorSectionModel, choices: [ImageColorSectionModel.Choice]) -> Binding<String> {
        Binding(get: { model.selection }, set: { id in
            if id == ImageColorSectionModel.other {
                Task { @MainActor in if let url = await chooseFile() { await model.assign(file: url).value } }
                return
            }
            switch choices.first(where: { $0.id == id })?.source {
            case .choice(let choice)?: model.panel.perform(model.assign(choice))
            case .file(let url)?: model.assign(file: url)
            case nil: break
            }
        })
    }

    static func intent(_ model: ImageColorSectionModel) -> Binding<String> {
        Binding(get: { model.intent }, set: { model.panel.perform(model.setIntent($0)) })
    }
}

struct ImageColorSectionView: View {
    let model: ImageColorSectionModel

    var body: some View {
        let choices = model.choices(installed: ImageColorSection.installed())
        Form {
            LabeledContent("Type", value: model.type).accessibilityIdentifier("object.image.type")
            Picker("Source profile", selection: ImageColorSection.source(model, choices: choices)) {
                if model.selection == ImageColorSectionModel.mixed { Text("Mixed").tag(ImageColorSectionModel.mixed) }
                ForEach(choices, id: \.id) { Text($0.title).tag($0.id) }
                Text("Other…").tag(ImageColorSectionModel.other)
            }
            .accessibilityIdentifier("object.image.source")
            Picker("Intent", selection: ImageColorSection.intent(model)) {
                if model.intent == ImageColorSectionModel.mixed { Text("Mixed").tag(ImageColorSectionModel.mixed) }
                ForEach(ImageColorSectionModel.intents, id: \.1) { Text($0.1).tag($0.1) }
            }
            .accessibilityIdentifier("object.image.intent")
        }
        .padding(.horizontal)
    }
}
