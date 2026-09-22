import Foundation

/// The window edges a group can dock at.
enum DockEdge: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case left, right
}

/// A floating group's frame in screen points, stored as `[x, y, width, height]`.
struct LayoutRect: Equatable, Sendable, Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var maxX: Double { x + width }
    var maxY: Double { y + height }

    func intersects(_ other: LayoutRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
        width = try container.decode(Double.self)
        height = try container.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(width)
        try container.encode(height)
    }
}

/// A tabbed set of panels: the unit that docks, floats and collapses.
struct PanelGroup: Codable, Equatable, Sendable, Identifiable {
    typealias ID = String

    var id: ID
    /// `nil` means the group is named after its panels.
    var name: String?
    var panels: [PanelID]
    /// The front tab; `nil` falls back to the first panel.
    var activePanel: PanelID?
    var collapsed: Bool
    /// Content height in the dock; `nil` uses the default.
    var height: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, panels, collapsed, height
        case activePanel = "active"
    }

    init(
        id: ID = UUID().uuidString, name: String? = nil, panels: [PanelID], activePanel: PanelID? = nil,
        collapsed: Bool = false, height: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.panels = panels
        self.activePanel = activePanel ?? panels.first
        self.collapsed = collapsed
        self.height = height
    }

    /// A file without an `id` (the Panels page's sample) gets one from the name.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        let panels = try container.decode([PanelID].self, forKey: .panels)
        self.init(
            id: try container.decodeIfPresent(ID.self, forKey: .id) ?? name.map(Self.id(forName:)) ?? UUID().uuidString,
            name: name,
            panels: panels,
            activePanel: try container.decodeIfPresent(PanelID.self, forKey: .activePanel),
            collapsed: try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false,
            height: try container.decodeIfPresent(Double.self, forKey: .height)
        )
    }

    /// The default layout's group ids come from the group name, so the default layout is
    /// reproducible and a panel registered later finds its group.
    static func id(forName name: String) -> ID {
        String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    var effectiveActivePanel: PanelID? {
        if let activePanel, panels.contains(activePanel) { return activePanel }
        return panels.first
    }

    /// The title bar text: the name, or every panel's title.
    func displayName(titles: (PanelID) -> String) -> String {
        name ?? panels.map(titles).joined(separator: " / ")
    }
}

/// A group floating over the document window.  Encoded flat: the group's fields plus `frame`
/// and `display`, as the Panels page shows.
struct FloatingGroup: Equatable, Sendable, Codable {
    var group: PanelGroup
    var frame: LayoutRect
    /// The display the frame is on; `nil` after being moved onto the main display.
    var display: String?

    init(group: PanelGroup, frame: LayoutRect, display: String? = nil) {
        self.group = group
        self.frame = frame
        self.display = display
    }

    enum CodingKeys: String, CodingKey {
        case frame, display
    }

    init(from decoder: Decoder) throws {
        group = try PanelGroup(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frame = try container.decode(LayoutRect.self, forKey: .frame)
        display = try container.decodeIfPresent(String.self, forKey: .display)
    }

    func encode(to encoder: Encoder) throws {
        try group.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frame, forKey: .frame)
        try container.encodeIfPresent(display, forKey: .display)
    }
}

/// Where the panels are.  A value type: every operation is a pure transformation, so layouts
/// can be tested without a window and compared for equality.  Persisted as JSON by
/// `PanelLayoutStore`.
struct PanelLayout: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let defaultDockWidth: [DockEdge: Double] = [.right: 280, .left: 44]
    static let minimumDockWidth: Double = 44
    static let defaultGroupHeight: Double = 220

    var version: Int
    var docks: [DockEdge: [PanelGroup]]
    var floating: [FloatingGroup]
    var dockWidth: [DockEdge: Double]
    /// Docks hidden with the dock handle or menu:View[Panels]; their groups keep their place.
    var hiddenDocks: Set<DockEdge>

    init(
        version: Int = PanelLayout.currentVersion, docks: [DockEdge: [PanelGroup]] = [:],
        floating: [FloatingGroup] = [], dockWidth: [DockEdge: Double] = PanelLayout.defaultDockWidth,
        hiddenDocks: Set<DockEdge> = []
    ) {
        self.version = version
        self.docks = docks
        self.floating = floating
        self.dockWidth = dockWidth
        self.hiddenDocks = hiddenDocks
    }

    enum CodingKeys: String, CodingKey {
        case version, docks, floating, dockWidth, hiddenDocks
    }

    /// Lenient about missing keys so a hand-edited or older file still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? PanelLayout.currentVersion
        docks = try container.decodeIfPresent([DockEdge: [PanelGroup]].self, forKey: .docks) ?? [:]
        floating = try container.decodeIfPresent([FloatingGroup].self, forKey: .floating) ?? []
        dockWidth = try container.decodeIfPresent([DockEdge: Double].self, forKey: .dockWidth) ?? PanelLayout.defaultDockWidth
        hiddenDocks = try container.decodeIfPresent(Set<DockEdge>.self, forKey: .hiddenDocks) ?? []
    }

    /// The factory layout: one group per distinct `defaultGroup`, in the order the descriptors
    /// name them, all docked at `edge`, every group expanded with its first panel in front.
    static func standard(for descriptors: [PanelDescriptor], edge: DockEdge = .right) -> PanelLayout {
        var groups: [PanelGroup] = []
        var indexByName: [String: Int] = [:]
        for descriptor in descriptors {
            if let index = indexByName[descriptor.defaultGroup] {
                groups[index].panels.append(descriptor.id)
            } else {
                indexByName[descriptor.defaultGroup] = groups.count
                groups.append(PanelGroup(
                    id: PanelGroup.id(forName: descriptor.defaultGroup), name: descriptor.defaultGroup,
                    panels: [descriptor.id]
                ))
            }
        }
        return PanelLayout(docks: groups.isEmpty ? [:] : [edge: groups])
    }

    // MARK: Queries

    enum GroupLocation: Equatable, Sendable {
        case docked(DockEdge, Int)
        case floating(Int)
    }

    /// Every group: docked left, docked right, then floating.
    var groups: [PanelGroup] {
        DockEdge.allCases.flatMap { docks[$0] ?? [] } + floating.map(\.group)
    }

    var panelIDs: [PanelID] { groups.flatMap(\.panels) }

    func contains(_ panel: PanelID) -> Bool { group(containing: panel) != nil }

    func group(_ id: PanelGroup.ID) -> PanelGroup? {
        groups.first { $0.id == id }
    }

    func group(containing panel: PanelID) -> PanelGroup? {
        groups.first { $0.panels.contains(panel) }
    }

    func location(of id: PanelGroup.ID) -> GroupLocation? {
        for edge in DockEdge.allCases {
            if let index = docks[edge]?.firstIndex(where: { $0.id == id }) { return .docked(edge, index) }
        }
        if let index = floating.firstIndex(where: { $0.group.id == id }) { return .floating(index) }
        return nil
    }

    /// A panel is visible when it is the front tab of an expanded group on a shown dock or
    /// floating.
    func isVisible(_ panel: PanelID) -> Bool {
        guard let group = group(containing: panel), !group.collapsed, group.effectiveActivePanel == panel,
            let location = location(of: group.id)
        else { return false }
        if case let .docked(edge, _) = location { return !hiddenDocks.contains(edge) }
        return true
    }

    // MARK: Operations

    private mutating func update(group id: PanelGroup.ID, _ change: (inout PanelGroup) -> Void) {
        switch location(of: id) {
        case let .docked(edge, index): change(&docks[edge]![index])
        case let .floating(index): change(&floating[index].group)
        case nil: break
        }
    }

    private mutating func extract(group id: PanelGroup.ID) -> PanelGroup? {
        switch location(of: id) {
        case let .docked(edge, index): return docks[edge]!.remove(at: index)
        case let .floating(index): return floating.remove(at: index).group
        case nil: return nil
        }
    }

    private mutating func insert(_ group: PanelGroup, at edge: DockEdge, index: Int?) {
        var list = docks[edge] ?? []
        list.insert(group, at: min(max(index ?? list.count, 0), list.count))
        docks[edge] = list
    }

    private static func removing(_ panel: PanelID, from group: PanelGroup) -> PanelGroup? {
        var result = group
        result.panels.removeAll { $0 == panel }
        if result.panels.isEmpty { return nil }
        if result.activePanel == panel { result.activePanel = result.panels.first }
        return result
    }

    /// Takes `panel` out of the layout; a group left empty disappears.
    mutating func removePanel(_ panel: PanelID) {
        for edge in DockEdge.allCases where docks[edge] != nil {
            docks[edge] = docks[edge]!.compactMap { Self.removing(panel, from: $0) }
        }
        floating = floating.compactMap { floater in
            Self.removing(panel, from: floater.group).map { FloatingGroup(group: $0, frame: floater.frame, display: floater.display) }
        }
    }

    /// Moves `panel` into an existing group as its front tab (drag onto a tab strip, Group With).
    mutating func movePanel(_ panel: PanelID, toGroup id: PanelGroup.ID, at index: Int? = nil) {
        guard let target = group(id) else { return }
        if target.panels == [panel] {
            activate(panel)
            return
        }
        removePanel(panel)
        update(group: id) { group in
            group.panels.insert(panel, at: min(max(index ?? group.panels.count, 0), group.panels.count))
            group.activePanel = panel
            group.collapsed = false
        }
    }

    /// Splits `panel` into a new group docked at `edge` (drag onto the dock, New Panel Group).
    /// `index` is the position among the groups docked there before the move.
    @discardableResult
    mutating func movePanel(_ panel: PanelID, toNewGroupAt edge: DockEdge, index: Int? = nil) -> PanelGroup.ID {
        var insertion = index
        if let index, let current = group(containing: panel), current.panels == [panel],
            case let .docked(currentEdge, currentIndex)? = location(of: current.id), currentEdge == edge, currentIndex < index
        {
            insertion = index - 1
        }
        removePanel(panel)
        let group = PanelGroup(panels: [panel])
        insert(group, at: edge, index: insertion)
        return group.id
    }

    /// Splits `panel` into a new floating group.
    @discardableResult
    mutating func floatPanel(_ panel: PanelID, frame: LayoutRect) -> PanelGroup.ID {
        removePanel(panel)
        let group = PanelGroup(panels: [panel])
        floating.append(FloatingGroup(group: group, frame: frame))
        return group.id
    }

    /// Floats a docked group (Float Group).
    mutating func float(group id: PanelGroup.ID, frame: LayoutRect) {
        guard case .docked? = location(of: id), var group = extract(group: id) else { return }
        group.collapsed = false
        floating.append(FloatingGroup(group: group, frame: frame))
    }

    /// Docks a group at `edge` (Dock Group, drag to the dock edge), from floating or another edge.
    mutating func dock(group id: PanelGroup.ID, at edge: DockEdge, index: Int? = nil) {
        guard let group = extract(group: id) else { return }
        insert(group, at: edge, index: index)
    }

    mutating func setCollapsed(_ collapsed: Bool, group id: PanelGroup.ID) {
        update(group: id) { $0.collapsed = collapsed }
    }

    mutating func toggleCollapsed(group id: PanelGroup.ID) {
        update(group: id) { $0.collapsed.toggle() }
    }

    /// Brings `panel` to the front: its tab is selected, its group expanded, its dock shown.
    mutating func activate(_ panel: PanelID) {
        guard let group = group(containing: panel) else { return }
        update(group: group.id) {
            $0.activePanel = panel
            $0.collapsed = false
        }
        if case let .docked(edge, _)? = location(of: group.id) { hiddenDocks.remove(edge) }
    }

    /// Reorders a tab within its group.
    mutating func reorderPanel(_ panel: PanelID, to index: Int) {
        guard let group = group(containing: panel) else { return }
        update(group: group.id) { group in
            group.panels.removeAll { $0 == panel }
            group.panels.insert(panel, at: min(max(index, 0), group.panels.count))
        }
    }

    /// Renames a group; `nil` returns to the automatic name; an empty string is ignored.
    mutating func rename(group id: PanelGroup.ID, to name: String?) {
        if let name, name.isEmpty { return }
        update(group: id) { $0.name = name }
    }

    mutating func setHeight(_ height: Double?, group id: PanelGroup.ID) {
        update(group: id) { $0.height = height }
    }

    mutating func setFrame(_ frame: LayoutRect, floatingGroup id: PanelGroup.ID) {
        if case let .floating(index)? = location(of: id) { floating[index].frame = frame }
    }

    mutating func setDockWidth(_ width: Double, edge: DockEdge) {
        dockWidth[edge] = max(Self.minimumDockWidth, width)
    }

    mutating func setDockHidden(_ hidden: Bool, edge: DockEdge) {
        if hidden { hiddenDocks.insert(edge) } else { hiddenDocks.remove(edge) }
    }

    mutating func toggleDockHidden(_ edge: DockEdge) {
        setDockHidden(!hiddenDocks.contains(edge), edge: edge)
    }

    /// Drops every panel not in `registered` (a layout saved by a build that had more panels).
    mutating func prune(keeping registered: Set<PanelID>) {
        for panel in panelIDs where !registered.contains(panel) { removePanel(panel) }
    }

    /// Adds panels the layout does not have yet to their default group, creating the group at
    /// `edge` when it does not exist.  Called after loading, so a panel a later task registers
    /// appears without a reset.
    mutating func add(panels descriptors: [PanelDescriptor], edge: DockEdge = .right) {
        for descriptor in descriptors where !contains(descriptor.id) {
            let defaultID = PanelGroup.id(forName: descriptor.defaultGroup)
            if group(defaultID) != nil {
                update(group: defaultID) { $0.panels.append(descriptor.id) }
            } else if let named = groups.first(where: { $0.name == descriptor.defaultGroup }) {
                update(group: named.id) { $0.panels.append(descriptor.id) }
            } else {
                insert(PanelGroup(id: defaultID, name: descriptor.defaultGroup, panels: [descriptor.id]), at: edge, index: nil)
            }
        }
    }

    /// Moves floating groups whose frame is off every display onto `screen`.
    mutating func moveOffscreenFloatingGroups(onto screen: LayoutRect) {
        for index in floating.indices where !floating[index].frame.intersects(screen) {
            floating[index].frame.x = screen.x + 40
            floating[index].frame.y = screen.maxY - floating[index].frame.height - 40
            floating[index].display = nil
        }
    }
}
