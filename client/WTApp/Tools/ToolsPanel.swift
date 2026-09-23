import AppKit
import Observation
import SwiftUI

/// What the Tools panel shows: the registered tools and the key window's active tool.
/// BASIC-009 replaces the body with the full panel (flyouts, wells, snap toggles) and docks it
/// at the left edge.
@MainActor
@Observable
final class ToolPaletteModel {
    private(set) var descriptors: [ToolDescriptor] = []
    /// The key document window's effective tool; nil without a document window.
    var activeToolID: ToolID?
    @ObservationIgnored var select: @MainActor (ToolID) -> Void = { _ in }

    init() {}

    func reload(from registry: ToolRegistry) {
        descriptors = registry.descriptors
    }

    func descriptors(in section: ToolSection) -> [ToolDescriptor] {
        descriptors.filter { $0.section == section }
    }
}

struct ToolsPanelBody: View {
    let model: ToolPaletteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            section(.tools)
            Divider()
            section(.view)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func section(_ section: ToolSection) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 6), alignment: .leading, spacing: 4) {
            ForEach(model.descriptors(in: section)) { descriptor in
                Button {
                    model.select(descriptor.id)
                } label: {
                    Image(systemName: descriptor.symbolName)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.borderless)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(model.activeToolID == descriptor.id ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .help(descriptor.shortcut.map { "\(descriptor.title) (\($0.displayString))" } ?? descriptor.title)
                .accessibilityLabel(descriptor.title)
                .accessibilityIdentifier(descriptor.commandID.rawValue)
            }
        }
    }
}

enum ToolsPanel {
    static let id: PanelID = "tools"

    @MainActor
    static func descriptor(model: ToolPaletteModel) -> PanelDescriptor {
        PanelDescriptor(id: id, title: "Tools", defaultGroup: "Tools", menuOrder: 0, helpSlug: "toolbars") {
            ToolsPanelBody(model: model)
        }
    }
}

/// The transparent layer above the tiles that tools draw handles and previews into
/// (client.adoc, "The document window").  Redrawn per event, never per frame.  Its drawing
/// context is flipped to view points (y down) before the tool draws.
final class CanvasOverlayLayer: CALayer {
    /// Draws the overlay in view points; set by the canvas view.
    nonisolated(unsafe) var drawer: (@MainActor (CGContext) -> Void)?

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CanvasOverlayLayer is built in code")
    }

    override func draw(in ctx: CGContext) {
        guard let drawer else { return }
        let height = bounds.height
        // Core Animation draws layers on the main thread for a layer tree it displays; the
        // context is used synchronously and never escapes.
        nonisolated(unsafe) let context = ctx
        MainActor.assumeIsolated {
            context.saveGState()
            context.translateBy(x: 0, y: height)
            context.scaleBy(x: 1, y: -1)
            drawer(context)
            context.restoreGState()
        }
    }
}
