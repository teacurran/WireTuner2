import AppKit
import Foundation
import WTCRDT
import WTGeometry
import WTModel
import WTRender
@testable import WireTuner

/// A document window over a new document with a pasteboard of its own, for the model-glue tests
/// (envelopes, text on a path, perspective, Show Links, the path clean-ups, Inspect).
@MainActor
struct GlueWorld {
    let setup: SetupWindow
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("fxgl-\(UUID().uuidString)"))
    let presented = TestBox<[NSWindow]>([])

    init() {
        setup = SetupWindow(tools: [PointerTool.descriptor])
        setup.window.objectEditing.pasteboard = SystemObjectPasteboard(pasteboard)
    }

    var window: DocumentWindowController { setup.window }
    var document: DocumentHandle { setup.document }
    var commands: CommandRegistry { setup.environment.commands }
    var preferences: PreferenceStore { setup.environment.preferences }
    var state: EngineState { document.state }
    var editing: ObjectEditing { window.objectEditing }
    var target: ObjectMenuCommands.Target {
        let window = window
        return { window.objectEditing }
    }

    /// A sheet presenter that records what it shows instead of showing it.
    func sheets() -> SheetPresenter {
        let presenter = SheetPresenter()
        let presented = presented
        presenter.present = { presented.value.append($0) }
        return presenter
    }

    func select(_ ids: [OpID]) { window.selection.model.set(Selection(ids.map { SelectionID($0) })) }

    /// Waits for the selection to hold one node of `kind`.
    func waitForSelection(_ kind: NodeKind) async -> OpID? {
        for _ in 0..<400 {
            if let id = window.selection.selection.ids.first, state.nodeKind(id.opID) == kind { return id.opID }
            await Task.yield()
        }
        return nil
    }

    /// A tool context over the window's document with a recording host at the window's viewport.
    func context(_ host: RecordingHost) -> ToolContext {
        ToolContext(document: document, host: host, selection: window.selection)
    }

    func bitmap() -> CGContext {
        CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    func close() {
        pasteboard.releaseGlobally()
        setup.close()
    }
}
