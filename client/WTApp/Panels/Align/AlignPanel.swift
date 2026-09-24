import AppKit
import Observation
import SwiftUI
import WTGeometry
import WTModel
import WTProto

/// The Align panel's state (arranging.adoc, "Aligning and distributing"; OBJ-019): the settings,
/// remembered in the preferences' defaults so btn:[Apply] on a new selection repeats them.
@MainActor
@Observable
final class AlignPanelState {
    var settings: AlignSettings {
        didSet { if let defaults { settings.save(to: defaults) } }
    }

    @ObservationIgnored let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        settings = defaults.map(AlignSettings.init(defaults:)) ?? AlignSettings()
    }

    /// btn:[Apply] on the front window's selection.
    @discardableResult
    func apply(_ selection: ActiveSelection?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let document = selection?.document, let current = selection?.model?.selection,
              let command = AlignTarget(document: document, selection: current).command(settings) else { return nil }
        return selection?.editing?.perform(command) ?? document.perform(command)
    }

    /// A click in the preview at `point` of a preview `size` big.
    func click(at point: CGPoint, in size: CGSize) {
        let (horizontal, vertical) = AlignPreview.options(at: point, in: size)
        settings.horizontal = horizontal
        settings.vertical = vertical
    }
}

/// The clickable preview: an edge band aligns to that edge, the middle band centres, and the
/// three rectangles (four with a distribution) show the setting.
enum AlignPreview {
    /// The share of the preview each edge band takes.
    static let band = 0.25

    /// The options a click at `point` stands for: left/centre/right by x, top/centre/bottom by y.
    static func options(at point: CGPoint, in size: CGSize) -> (AlignOption, AlignOption) {
        func option(_ value: Double, _ length: Double) -> AlignOption {
            guard length > 0 else { return .none }
            let fraction = value / length
            if fraction < band { return .minEdge }
            if fraction > 1 - band { return .maxEdge }
            return .center
        }
        return (option(point.x, size.width), option(point.y, size.height))
    }

    /// The preview's rectangles in a unit square: three (four for a distribution) sample boxes
    /// laid out by the settings.
    static func boxes(_ settings: AlignSettings) -> [CGRect] {
        let distributing = settings.horizontal.isDistribution || settings.vertical.isDistribution
        var samples: [WTGeometry.Rect] = [
            .init(x: 0.10, y: 0.15, width: 0.22, height: 0.30),
            .init(x: 0.40, y: 0.45, width: 0.14, height: 0.20),
            .init(x: 0.60, y: 0.25, width: 0.26, height: 0.40),
        ]
        if distributing { samples.append(.init(x: 0.30, y: 0.70, width: 0.18, height: 0.16)) }
        let offsets = AlignLayout.offsets(samples.map { AlignLayout.Item(box: $0) }, settings: AlignSettings(horizontal: settings.horizontal, vertical: settings.vertical), page: nil)
        return zip(samples, offsets).map { CGRect(x: $0.minX + $1.dx, y: $0.minY + $1.dy, width: $0.width, height: $0.height) }
    }
}

struct AlignPanelBody: View {
    let selection: ActiveSelection?
    let state: AlignPanelState

    static func option(_ state: AlignPanelState, horizontal: Bool) -> Binding<AlignOption> {
        Binding(get: { horizontal ? state.settings.horizontal : state.settings.vertical },
                set: { if horizontal { state.settings.horizontal = $0 } else { state.settings.vertical = $0 } })
    }

    /// btn:[Apply].
    func apply() {
        state.apply(selection)
    }

    static func toPage(_ state: AlignPanelState) -> Binding<Bool> {
        Binding(get: { state.settings.toPage }, set: { state.settings.toPage = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                Canvas { context, size in
                    context.stroke(Path(CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)), with: .color(.secondary))
                    for box in AlignPreview.boxes(state.settings) {
                        let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
                        context.fill(Path(rect), with: .color(.accentColor.opacity(0.6)))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { state.click(at: $0, in: proxy.size) }
            }
            .frame(height: 90)
            .accessibilityIdentifier("align.preview")
            Picker("Horizontal", selection: Self.option(state, horizontal: true)) {
                ForEach(AlignOption.allCases) { Text($0.title(horizontal: true)).tag($0) }
            }
            .accessibilityIdentifier("align.horizontal")
            Picker("Vertical", selection: Self.option(state, horizontal: false)) {
                ForEach(AlignOption.allCases) { Text($0.title(horizontal: false)).tag($0) }
            }
            .accessibilityIdentifier("align.vertical")
            Toggle("Align to page", isOn: Self.toPage(state)).accessibilityIdentifier("align.toPage")
            HStack {
                Spacer()
                Button("Apply", action: apply).keyboardShortcut(.defaultAction).accessibilityIdentifier("align.apply")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The Align panel's registration (it replaces the catalog's placeholder) and the
/// menu:Modify[Align] items, each a one-axis alignment of the selection.
enum AlignPanel {
    static func descriptor(selection: ActiveSelection?, state: AlignPanelState) -> PanelDescriptor {
        PanelDescriptor(id: "align", title: "Align", icon: "align.horizontal.left", defaultGroup: PanelCatalog.Group.alignTransform,
                        menuOrder: 50, helpSlug: "arranging") {
            AlignPanelBody(selection: selection, state: state)
        }
    }

    /// The menu:Modify[Align] items: (id, title, settings).
    static let menuItems: [(CommandID, String, AlignSettings)] = {
        let ids = ContextMenuCatalog.ID.self
        return [
            (ids.alignLeft, "Left", AlignSettings(horizontal: .minEdge)),
            (ids.alignCenterHorizontal, "Center Horizontally", AlignSettings(horizontal: .center)),
            (ids.alignRight, "Right", AlignSettings(horizontal: .maxEdge)),
            (ids.alignTop, "Top", AlignSettings(vertical: .minEdge)),
            (ids.alignCenterVertical, "Center Vertically", AlignSettings(vertical: .center)),
            (ids.alignBottom, "Bottom", AlignSettings(vertical: .maxEdge)),
        ]
    }()

    static func commands(target: @escaping @MainActor () -> ObjectEditing?) -> [Command] {
        let modify = ContextMenuCatalog.Menu.modify
        return menuItems.map { id, title, settings in
            Command(id: id, title: title, menu: MenuPath(modify, "Align", section: 2), contexts: ContextMenuCatalog.objectContexts, keywords: ["align"],
                    validation: { target()?.hasSelection == true ? .enabled : .disabled(ObjectMenuCommands.noSelection) },
                    action: .perform {
                        guard let editing = target(),
                              let command = AlignTarget(document: editing.document, selection: editing.selection.selection).command(settings) else { return }
                        editing.perform(command)
                    })
        }
    }
}
