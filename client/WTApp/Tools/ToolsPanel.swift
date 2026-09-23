import AppKit
import Observation
import SwiftUI
import WTRender

/// One slot of the Tools panel: a tool of its own, or a flyout showing one member.
enum ToolSlot: Identifiable, Equatable, Sendable {
    case tool(ToolID)
    case flyout(FlyoutGroup, visible: ToolID, members: [ToolID])

    var id: String {
        switch self {
        case let .tool(id): id.rawValue
        case let .flyout(group, _, _): "flyout.\(group.rawValue)"
        }
    }

    /// The tool the slot's button shows.
    var visibleTool: ToolID {
        switch self {
        case let .tool(id), let .flyout(_, id, _): id
        }
    }
}

/// Which well *None* acts on.
enum ActiveWell: Sendable {
    case stroke, fill
}

/// The four snap toggles: `local_only` view state of the window (`ViewState.snap_*`,
/// document-view.adoc).
struct SnapSettings: Codable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case point, object, grid, guides

        var title: String {
            switch self {
            case .point: "Snap to Point"
            case .object: "Snap to Object"
            case .grid: "Snap to Grid"
            case .guides: "Snap to Guides"
            }
        }

        var symbol: String {
            switch self {
            case .point: "smallcircle.filled.circle"
            case .object: "point.topleft.down.to.point.bottomright.curvepath"
            case .grid: "grid"
            case .guides: "ruler"
            }
        }
    }

    var point = true
    var object = true
    var grid = false
    var guides = true

    subscript(kind: Kind) -> Bool {
        get {
            switch kind {
            case .point: point
            case .object: object
            case .grid: grid
            case .guides: guides
            }
        }
        set {
            switch kind {
            case .point: point = newValue
            case .object: object = newValue
            case .grid: grid = newValue
            case .guides: guides = newValue
            }
        }
    }
}

/// What the Tools panel shows (BASIC-009): the registered tools in slots, the key window's
/// tool, view mode and snap settings, and the wells.  The flyout slots live in the panel layout
/// (`slotStore`), so they persist with it.
@MainActor
@Observable
final class ToolPaletteModel {
    private(set) var descriptors: [ToolDescriptor] = []
    /// The key document window's effective tool; nil without a document window.
    var activeToolID: ToolID? {
        didSet { if let activeToolID { rememberSlot(for: activeToolID) } }
    }
    /// The key window's drawing mode and snap toggles; nil without a document window.
    var viewMode: ViewMode?
    var snap: SnapSettings?
    /// The selection's colours; nil with nothing selected (the wells then show the defaults).
    var selectionWells: WellColors?
    /// The colours new objects get (Swap, None and Default act on them).
    private(set) var defaultWells = WellColors.standard
    var activeWell: ActiveWell = .fill
    var showsTooltips = true
    /// Bumped when a flyout slot changes.
    private(set) var slotRevision = 0

    @ObservationIgnored var select: @MainActor (ToolID) -> Void = { _ in }
    @ObservationIgnored var presentOptions: @MainActor (ToolDescriptor) -> Void = { _ in }
    /// Runs a command (Keyline, Fast Mode, the snap toggles) as its shortcut would.
    @ObservationIgnored var perform: @MainActor (CommandID) -> Void = { _ in }
    /// Where the flyout slots are kept (`PanelLayoutController`); in memory until connected.
    @ObservationIgnored var slotStore: (get: @MainActor (String) -> String?, set: @MainActor (String, String) -> Void)
    @ObservationIgnored private var slots: [String: String] = [:]
    /// The buttons added to the Tools panel in Customize Toolbars (BASIC-029), after the
    /// Snap section; nil until the toolbars are installed.
    @ObservationIgnored var extraItems: (@MainActor () -> AnyView)?

    init() {
        slotStore = (get: { _ in nil }, set: { _, _ in })
        slotStore = (get: { [unowned self] in self.slots[$0] }, set: { [unowned self] in self.slots[$0] = $1 })
    }

    func reload(from registry: ToolRegistry) {
        descriptors = registry.descriptors
    }

    func descriptor(for id: ToolID) -> ToolDescriptor? {
        descriptors.first { $0.id == id }
    }

    func descriptors(in section: ToolSection) -> [ToolDescriptor] {
        descriptors.filter { $0.section == section }
    }

    func members(of group: FlyoutGroup) -> [ToolDescriptor] {
        descriptors.filter { $0.group == group }
    }

    /// The member a flyout shows: the last one chosen, else its first.
    func visibleMember(of group: FlyoutGroup) -> ToolID? {
        _ = slotRevision
        let members = members(of: group).map(\.id)
        if let stored = slotStore.get(group.rawValue).map(ToolID.init(rawValue:)), members.contains(stored) { return stored }
        return members.first
    }

    /// The section's slots in registration order, one per flyout.
    func slots(in section: ToolSection) -> [ToolSlot] {
        var seen: Set<FlyoutGroup> = []
        return descriptors(in: section).compactMap { descriptor in
            guard let group = descriptor.group else { return .tool(descriptor.id) }
            guard seen.insert(group).inserted, let visible = visibleMember(of: group) else { return nil }
            return .flyout(group, visible: visible, members: members(of: group).map(\.id))
        }
    }

    private func rememberSlot(for id: ToolID) {
        guard let group = descriptor(for: id)?.group, visibleMember(of: group) != id else { return }
        slotStore.set(group.rawValue, id.rawValue)
        slotRevision += 1
    }

    /// A click in the panel or a flyout menu: the tool becomes current and takes its slot.
    func choose(_ id: ToolID) {
        rememberSlot(for: id)
        select(id)
    }

    /// A tool shortcut.  Pressing the key of the visible, current member of a flyout (or of
    /// the flyout's first member while another member is current and visible) advances to the
    /// next member; any other key selects its tool directly.
    func pressShortcut(_ id: ToolID) {
        guard let group = descriptor(for: id)?.group, let active = activeToolID, descriptor(for: active)?.group == group,
            visibleMember(of: group) == active
        else { return choose(id) }
        let members = members(of: group).map(\.id)
        guard id == active || id == members.first, let index = members.firstIndex(of: active) else { return choose(id) }
        choose(members[(index + 1) % members.count])
    }

    /// Double-click: the tool's options sheet, when it has one.
    func showOptions(_ id: ToolID) {
        guard let descriptor = descriptor(for: id), descriptor.options != nil else { return }
        presentOptions(descriptor)
    }

    // MARK: Wells

    var wells: WellColors { selectionWells ?? defaultWells }

    /// Swap, None and Default change the default colours; changing the selection's colours
    /// waits for the model's appearance commands.
    var canEditWells: Bool { selectionWells == nil }

    func swapWells() {
        guard canEditWells else { return }
        defaultWells = WellColors(stroke: defaultWells.fill, fill: defaultWells.stroke)
    }

    func setActiveWellToNone() {
        guard canEditWells else { return }
        switch activeWell {
        case .stroke: defaultWells.stroke = .none
        case .fill: defaultWells.fill = .none
        }
    }

    func restoreDefaultWells() {
        guard canEditWells else { return }
        defaultWells = .standard
    }

    func tooltip(_ text: String) -> String? { showsTooltips ? text : nil }
}

/// The Tools panel (toolbars.adoc, "The Tools panel"): Tools, View, Colors and Snap sections,
/// two columns when docked at a side, one row when docked at the top or bottom.
struct ToolsPanelBody: View {
    let model: ToolPaletteModel

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                ScrollView(.horizontal) {
                    HStack(alignment: .center, spacing: 6) { sections(horizontal: true) }.padding(6)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) { sections(horizontal: false) }.padding(6)
                }
            }
        }
        .accessibilityIdentifier("panel.tools")
    }

    @ViewBuilder private func sections(horizontal: Bool) -> some View {
        slotGrid(model.slots(in: .tools), horizontal: horizontal)
        Divider()
        slotGrid(model.slots(in: .view) , horizontal: horizontal)
        viewToggles(horizontal: horizontal)
        Divider()
        ToolWellsView(model: model)
        Divider()
        snapToggles(horizontal: horizontal)
        if let extraItems = model.extraItems { extraItems() }
    }

    @ViewBuilder private func slotGrid(_ slots: [ToolSlot], horizontal: Bool) -> some View {
        if horizontal {
            HStack(spacing: 2) { ForEach(slots) { ToolSlotButton(model: model, slot: $0) } }
        } else {
            LazyVGrid(columns: [GridItem(.fixed(32), spacing: 2), GridItem(.fixed(32), spacing: 2)], alignment: .leading, spacing: 2) {
                ForEach(slots) { ToolSlotButton(model: model, slot: $0) }
            }
        }
    }

    @ViewBuilder private func viewToggles(horizontal: Bool) -> some View {
        let mode = model.viewMode
        let buttons = Group {
            toggle("Keyline", symbol: "square.dashed", isOn: mode?.isKeyline ?? false, command: StandardCommands.ID.keyline, identifier: "tools.keyline")
            toggle("Fast Mode", symbol: "hare", isOn: mode?.isFast ?? false, command: StandardCommands.ID.fastMode, identifier: "tools.fastMode")
        }
        if horizontal { HStack(spacing: 2) { buttons } } else { HStack(spacing: 2) { buttons } }
    }

    @ViewBuilder private func snapToggles(horizontal: Bool) -> some View {
        let snap = model.snap ?? SnapSettings()
        let columns = [GridItem(.fixed(32), spacing: 2), GridItem(.fixed(32), spacing: 2)]
        let toggles = ForEach(SnapSettings.Kind.allCases, id: \.self) { kind in
            toggle(kind.title, symbol: kind.symbol, isOn: snap[kind], command: ToolPanelCommands.snapCommandID(kind), identifier: "tools.snap.\(kind.rawValue)")
        }
        if horizontal { HStack(spacing: 2) { toggles } } else { LazyVGrid(columns: columns, alignment: .leading, spacing: 2) { toggles } }
    }

    private func toggle(_ title: String, symbol: String, isOn: Bool, command: CommandID, identifier: String) -> some View {
        Button { model.perform(command) } label: {
            Image(systemName: symbol).frame(width: 28, height: 24)
        }
        .buttonStyle(.borderless)
        .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? SwiftUI.Color.accentColor.opacity(0.25) : SwiftUI.Color.clear))
        .help(model.tooltip(title) ?? "")
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityIdentifier(identifier)
        .disabled(model.snap == nil && model.viewMode == nil)
    }
}

/// One tool slot: a button, or a flyout menu whose click selects the visible member and whose
/// press-and-hold lists the others.  Double-click opens the tool's options.
struct ToolSlotButton: View {
    let model: ToolPaletteModel
    let slot: ToolSlot

    var body: some View {
        let visible = model.descriptor(for: slot.visibleTool)
        let active = model.activeToolID == slot.visibleTool
        Group {
            switch slot {
            case .tool:
                Button { model.choose(slot.visibleTool) } label: { icon(visible, flyout: false) }
                    .buttonStyle(.borderless)
            case let .flyout(_, _, members):
                Menu {
                    ForEach(members, id: \.self) { member in
                        Button(model.descriptor(for: member)?.title ?? member.rawValue) { model.choose(member) }
                            .accessibilityIdentifier("tool.\(member.rawValue).flyout")
                    }
                    if visible?.options != nil {
                        Divider()
                        Button("\(visible?.title ?? "") Options…") { model.showOptions(slot.visibleTool) }
                    }
                } label: {
                    icon(visible, flyout: true)
                } primaryAction: {
                    model.choose(slot.visibleTool)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
        .frame(width: 32, height: 28)
        .background(RoundedRectangle(cornerRadius: 4).fill(active ? SwiftUI.Color.accentColor.opacity(0.25) : SwiftUI.Color.clear))
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.showOptions(slot.visibleTool) })
        .help(model.tooltip(visible?.tooltip ?? "") ?? "")
        .accessibilityLabel(visible?.title ?? slot.visibleTool.rawValue)
        .accessibilityIdentifier(ToolRegistry.commandID(for: slot.visibleTool).rawValue)
    }

    private func icon(_ descriptor: ToolDescriptor?, flyout: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: descriptor?.symbolName ?? "questionmark").frame(width: 28, height: 24)
            if flyout {
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 5)).foregroundStyle(.secondary).offset(x: -1, y: -1)
            }
        }
    }
}

/// The stroke and fill wells with Swap, None and Default.
struct ToolWellsView: View {
    let model: ToolPaletteModel

    var body: some View {
        let wells = model.wells
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                well(wells.fill, well: .fill).offset(x: 10, y: 10)
                well(wells.stroke, well: .stroke)
            }
            .frame(width: 44, height: 40, alignment: .topLeading)
            HStack(spacing: 2) {
                small("arrow.left.arrow.right", "Swap", identifier: "tools.wells.swap") { model.swapWells() }
                small("nosign", "None", identifier: "tools.wells.none") { model.setActiveWellToNone() }
                small("circle.lefthalf.filled", "Default", identifier: "tools.wells.default") { model.restoreDefaultWells() }
            }
            .disabled(!model.canEditWells)
        }
    }

    private func well(_ paint: Paint, well: ActiveWell) -> some View {
        let color = paint.color.map { SwiftUI.Color(red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha) }
        return RoundedRectangle(cornerRadius: 3)
            .fill(color ?? SwiftUI.Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(model.activeWell == well ? SwiftUI.Color.accentColor : SwiftUI.Color.secondary, lineWidth: well == .stroke ? 4 : 1))
            .overlay { if color == nil { Image(systemName: "line.diagonal").foregroundStyle(.red) } }
            .frame(width: 24, height: 24)
            .onTapGesture { model.activeWell = well }
            .accessibilityElement()
            .accessibilityLabel(well == .stroke ? "Stroke well" : "Fill well")
            .accessibilityIdentifier(well == .stroke ? "tools.wells.stroke" : "tools.wells.fill")
    }

    private func small(_ symbol: String, _ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 9)).frame(width: 14, height: 14) }
            .buttonStyle(.borderless)
            .help(model.tooltip(title) ?? "")
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
    }
}

enum ToolsPanel {
    static let id: PanelID = "tools"

    @MainActor
    static func descriptor(model: ToolPaletteModel) -> PanelDescriptor {
        PanelDescriptor(id: id, title: "Tools", icon: "hammer", defaultGroup: PanelCatalog.Group.tools, menuOrder: 0, helpSlug: "toolbars") {
            NSHostingView(rootView: ToolsPanelBody(model: model))
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
