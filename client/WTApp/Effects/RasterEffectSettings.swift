import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTRender

/// The raster effects resolution sheets (raster-effects.adoc, "Resolution"; FX-008): the document's
/// menu:File[Document Settings > Raster Effects…] (*Resolution*, *Optimal CMYK rendering*) and an
/// object's *Raster Effect Settings…* from the Object panel's options menu (*Use document raster
/// effects resolution*, *Resolution*).  btn:[OK] writes one change; btn:[Cancel] nothing.
@MainActor
@Observable
final class RasterSettingsModel {
    enum Target: Equatable {
        case document
        case objects([OpID])
    }

    let document: DocumentHandle
    let target: Target
    var resolution: Double
    var optimalCMYK: Bool
    var usesDocument: Bool
    private(set) var message: String?
    @ObservationIgnored var perform: @MainActor (any WTModel.Command) -> Void
    @ObservationIgnored var onClose: @MainActor () -> Void = {}

    init(document: DocumentHandle, target: Target, perform: @escaping @MainActor (any WTModel.Command) -> Void) {
        self.document = document
        self.target = target
        self.perform = perform
        let settings = ChangeRasterEffectSettings.read(document.state)
        optimalCMYK = settings.optimalCMYK
        switch target {
        case .document:
            resolution = Double(settings.resolution)
            usesDocument = true
        case .objects(let nodes):
            let own = shared(nodes.map { SetObjectRasterResolution.read($0, in: document.state) }) ?? 0
            usesDocument = own == 0
            resolution = Double(own == 0 ? settings.resolution : own)
        }
    }

    var title: String { target == .document ? "Raster Effects" : "Raster Effect Settings" }

    /// btn:[OK]: the one change, unless the resolution is out of range (1 to 2400 ppi).
    func ok() {
        let ppi = resolution.rounded()
        guard (1...2400).contains(ppi) || (target != .document && usesDocument) else {
            message = "The resolution must be from 1 to 2400 ppi."
            return
        }
        switch target {
        case .document:
            perform(ChangeRasterEffectSettings(resolution: UInt32(ppi), optimalCMYK: optimalCMYK))
        case .objects(let nodes):
            perform(SetObjectRasterResolution(nodes, ppi: usesDocument ? 0 : UInt32(ppi)))
        }
        onClose()
    }

    func cancel() { onClose() }
}

struct RasterSettingsSheet: View {
    @Bindable var model: RasterSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline)
            Form {
                if model.target != .document {
                    Toggle("Use document raster effects resolution", isOn: $model.usesDocument).accessibilityIdentifier("raster.usesDocument")
                }
                TextField("Resolution (ppi)", value: $model.resolution, format: .number)
                    .disabled(model.target != .document && model.usesDocument)
                    .accessibilityIdentifier("raster.resolution")
                if model.target == .document {
                    Toggle("Optimal CMYK rendering", isOn: $model.optimalCMYK).accessibilityIdentifier("raster.optimalCMYK")
                }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red).accessibilityIdentifier("raster.message")
            }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("raster.cancel")
                Button("OK", action: model.ok).keyboardShortcut(.defaultAction).accessibilityIdentifier("raster.ok")
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

/// The two sheets' commands and the *Raster effect preview* preference on each canvas.
@MainActor
final class RasterEffectSettingsFeatures {
    static let shared = RasterEffectSettingsFeatures()
    static let documentID: CommandID = "file.documentSettings.rasterEffects"
    static let noDocument = "No document is open"
    static let noSelection = "Select objects to give them their own resolution"

    var window: @MainActor () -> DocumentWindowController? = { nil }
    var presentSheet: @MainActor (NSWindow, NSWindow?) -> Void = { sheet, parent in
        if let parent { parent.beginSheet(sheet) } else { sheet.makeKeyAndOrderFront(nil) }
    }
    private(set) var sheet: NSWindow?

    init() {}

    @discardableResult
    func present(_ target: RasterSettingsModel.Target) -> RasterSettingsModel? {
        guard let window = window() else { return nil }
        let model = RasterSettingsModel(document: window.documentHandle, target: target) { [weak window] command in window?.objectEditing.perform(command) }
        model.onClose = { [weak self] in self?.dismiss() }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: RasterSettingsSheet(model: model)))
        sheet.identifier = NSUserInterfaceItemIdentifier("raster-settings-sheet")
        sheet.isReleasedWhenClosed = false
        sheet.animationBehavior = .none
        self.sheet = sheet
        presentSheet(sheet, window.window)
        return model
    }

    func dismiss() {
        guard let sheet else { return }
        self.sheet = nil
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
    }

    /// The Object panel options menu's item.
    func objectMenuItem() -> PanelMenuItem {
        let nodes = window()?.objectEditing.selectedNodes ?? []
        return PanelMenuItem(title: "Raster Effect Settings…", isEnabled: !nodes.isEmpty) { [weak self] in
            _ = self?.present(.objects(nodes))
        }
    }

    func command() -> Command {
        Command(id: Self.documentID, title: "Raster Effects…", menu: MenuPath(StandardCommands.Menu.file, "Document Settings", section: 5),
                keywords: ["raster", "resolution", "ppi", "effects", "cmyk"],
                validation: { [weak self] in self?.window() == nil ? .disabled(Self.noDocument) : .enabled },
                action: .perform { [weak self] in _ = self?.present(.document) })
    }

    /// The *Raster effect preview* preference as the renderer reads it.
    static func preview(_ value: String) -> RasterPreview {
        switch value {
        case "document": .document
        case "draft": .draft
        case "off": .off
        default: .screen
        }
    }

    /// Applies the preference to `window`'s canvas, now and whenever it changes.
    static func follow(_ window: DocumentWindowController, preferences: PreferenceStore) {
        let key = PreferenceCatalog.Redraw.rasterEffectPreview
        window.canvas.tiles.setRasterPreview(preview(preferences[key]))
        _ = preferences.observe { [weak window] change in
            guard change.id == key.id, let window else { return }
            window.canvas.tiles.setRasterPreview(preview(preferences[key]))
        }
    }
}
