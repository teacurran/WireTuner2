import AppKit
import SwiftUI
import WTModel

/// The Graphic Hose tool and its sheet in place of the catalog's stub (DRAW-039, DRAW-040), over
/// the library on this Mac: prepared at launch (the default hoses on the first one) and watched,
/// so a `.wthose` copied into the folder appears in the *Sets* pop-up.
@MainActor
enum HoseFeatures {
    /// The sheet the tool's double-click opens.
    static func sheet(model: GraphicHoseModel) -> NSViewController {
        _ = model.refreshLibrary()
        let controller = NSHostingController(rootView: GraphicHoseSheet(model: model, dismiss: {}))
        controller.rootView = GraphicHoseSheet(model: model) { [weak controller] in ToolOptionsPlaceholder.close(controller?.view.window) }
        controller.title = "Graphic Hose"
        return controller
    }

    static func descriptor(model: GraphicHoseModel) -> ToolDescriptor {
        var descriptor = ToolCatalog.all.first { $0.id == GraphicHoseTool.id }!.delivering { GraphicHoseTool(model: model) }
        descriptor.options = { sheet(model: model) }
        return descriptor
    }

    /// Prepares and watches the library, then lists it.
    @discardableResult
    static func start(_ model: GraphicHoseModel) -> Task<Void, Never> {
        let library = model.library
        return Task { @MainActor [weak model] in
            _ = try? await library.prepare()
            try? await library.startWatching { entries in
                Task { @MainActor in await model?.show(entries) }
            }
            await model?.refreshLibrary().value
        }
    }
}

extension AppDelegate {
    /// The Graphic Hose tool; a test launch keeps its library in a temporary folder.
    func installGraphicHose() {
        let directory = launchEnvironment.isTesting
            ? FileManager.default.temporaryDirectory.appending(path: "WireTuner-hoses-\(ProcessInfo.processInfo.processIdentifier)")
            : HoseLibrary.defaultDirectory()
        let model = GraphicHoseModel(selection: activeSelection, library: HoseLibrary(directory: directory))
        tools.replace(HoseFeatures.descriptor(model: model))
        HoseFeatures.start(model)
    }
}
