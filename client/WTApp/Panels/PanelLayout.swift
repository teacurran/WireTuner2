import Foundation

/// The window edges a group can dock at.  Panel groups dock left or right; the top and
/// bottom strips hold toolbars (the Tools panel docks at all four, toolbars.adoc).
enum DockEdge: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case left, right, top, bottom

    /// Left and right docks are columns; top and bottom are rows.
    var isVertical: Bool { self == .left || self == .right }
}

/// How the factory layout treats one default group (panels.adoc, "The default layout").
struct PanelGroupDefaults: Equatable, Sendable {
    /// Place in the dock, top first.
    var position: Int
    /// Open at first launch; a closed group's panels are in `PanelLayout.closedPanels`.
    var isOpen: Bool = true
    /// Collapsed to its title bar at first launch.
    var isCollapsed: Bool = false
    /// Keeps its name however its members change (Properties, Assets); other groups are named
    /// after their panels until renamed.
    var keepsName: Bool = false
    var edge: DockEdge = .right
    /// The body height the group asks for in a side dock until the user resizes it (docked
    /// groups share the dock's height in proportion to it); nil uses
    /// `PanelLayout.defaultGroupHeight`.
    var height: Double?
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
    /// Body height in a side dock, as the user last sized it with the dividers: docked groups
    /// share the dock's height in proportion to it.  `nil` uses the group's default.
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

/// A floating group as layouts before magnetic panels stored it, and as `PanelLayout.floating`
/// lists the groups of floating clusters.  Encoded flat: the group's fields plus `frame` and
/// `display` (version 1 files; read to migrate them).
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
///
/// Panel groups live in *clusters* (D-077, magnetic panels): at most one docked at each side
/// edge, and any number floating.  The top and bottom strips are rows of groups (toolbars and
/// the Tools panel when docked there).  Version 2 stores the clusters; a version 1 file's docked
/// groups become the cluster at that edge and each of its floating groups a cluster of its own.
struct PanelLayout: Codable, Equatable, Sendable {
    static let currentVersion = 2
    /// Width of the side docks' edge column, height of the top and bottom strips.
    static let defaultDockWidth: [DockEdge: Double] = [.right: 280, .left: 84, .top: 44, .bottom: 44]
    static let minimumDockWidth: Double = 44
    static let defaultGroupHeight: Double = 220

    var version: Int
    /// The top and bottom strips' groups, left first.
    var strips: [DockEdge: [PanelGroup]]
    /// Docked and floating clusters.
    var clusters: [PanelCluster]
    /// The height of the top and bottom strips; for the side edges, the width of the docked
    /// cluster's edge column (kept equal to it), or the width a cluster docked there next gets.
    var dockWidth: [DockEdge: Double]
    /// Docks hidden with the dock handle or menu:View[Panels]; their groups keep their place.
    var hiddenDocks: Set<DockEdge>
    /// Registered panels that are deliberately not in the layout (closed groups, and groups
    /// closed by the user); a reload does not bring them back.
    var closedPanels: Set<PanelID>
    /// The member each Tools panel flyout shows, by flyout group (toolbars.adoc: "the slot
    /// remembers the last chosen member per layout").
    var flyoutSlots: [String: String]

    init(
        version: Int = PanelLayout.currentVersion, docks: [DockEdge: [PanelGroup]] = [:],
        floating: [FloatingGroup] = [], dockWidth: [DockEdge: Double] = PanelLayout.defaultDockWidth,
        hiddenDocks: Set<DockEdge> = [], closedPanels: Set<PanelID> = [], flyoutSlots: [String: String] = [:]
    ) {
        self.version = version
        self.strips = [:]
        self.clusters = []
        self.dockWidth = dockWidth
        self.hiddenDocks = hiddenDocks
        self.closedPanels = closedPanels
        self.flyoutSlots = flyoutSlots
        self.docks = docks
        self.floating = floating
    }

    enum CodingKeys: String, CodingKey {
        case version, docks, clusters, floating, dockWidth, hiddenDocks, closedPanels, flyoutSlots
    }

    /// Lenient about missing keys so a hand-edited or older file still loads; a version 1 file
    /// (docked groups per edge, floating groups) is migrated to clusters.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? PanelLayout.currentVersion
        let docks = try container.decodeIfPresent([DockEdge: [PanelGroup]].self, forKey: .docks) ?? [:]
        dockWidth = try container.decodeIfPresent([DockEdge: Double].self, forKey: .dockWidth) ?? PanelLayout.defaultDockWidth
        hiddenDocks = try container.decodeIfPresent(Set<DockEdge>.self, forKey: .hiddenDocks) ?? []
        closedPanels = try container.decodeIfPresent(Set<PanelID>.self, forKey: .closedPanels) ?? []
        flyoutSlots = try container.decodeIfPresent([String: String].self, forKey: .flyoutSlots) ?? [:]
        strips = docks.filter { !$0.key.isVertical }
        clusters = try container.decodeIfPresent([PanelCluster].self, forKey: .clusters) ?? []
        // Version 1: the side edges' groups become the cluster docked there (unless the file
        // already has one), each floating group a floating cluster of its own.
        for edge in [DockEdge.left, .right] where dockedClusterIndex(edge) == nil {
            guard let groups = docks[edge], !groups.isEmpty else { continue }
            let width = dockWidth[edge] ?? Self.defaultDockWidth[edge] ?? 280
            clusters.append(PanelCluster(id: uniqueClusterID(edge.rawValue), edge: edge, columns: [PanelColumn(groups: groups, width: width)]))
        }
        for floater in try container.decodeIfPresent([FloatingGroup].self, forKey: .floating) ?? [] {
            clusters.append(.floating(floater.group, id: uniqueClusterID(floater.group.id), frame: floater.frame, display: floater.display))
        }
        if version < Self.currentVersion { version = Self.currentVersion }
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(strips, forKey: .docks)
        try container.encode(clusters, forKey: .clusters)
        try container.encode(dockWidth, forKey: .dockWidth)
        try container.encode(hiddenDocks, forKey: .hiddenDocks)
        try container.encode(closedPanels, forKey: .closedPanels)
        try container.encode(flyoutSlots, forKey: .flyoutSlots)
    }

    /// The factory layout: one group per distinct `defaultGroup`, ordered and shown as
    /// `defaults` says (groups it does not name follow in descriptor order, open, expanded, at
    /// `edge`, keeping their name), each with its first panel in front.
    static func standard(for descriptors: [PanelDescriptor], groups defaults: [String: PanelGroupDefaults] = [:], edge: DockEdge = .right) -> PanelLayout {
        var names: [String] = []
        var members: [String: [PanelID]] = [:]
        for descriptor in descriptors {
            if members[descriptor.defaultGroup] == nil { names.append(descriptor.defaultGroup) }
            members[descriptor.defaultGroup, default: []].append(descriptor.id)
        }
        let ordered = names.enumerated().sorted { lhs, rhs in
            let l = (defaults[lhs.element]?.position ?? Int.max, lhs.offset)
            let r = (defaults[rhs.element]?.position ?? Int.max, rhs.offset)
            return l < r
        }.map(\.element)
        var layout = PanelLayout()
        for name in ordered {
            let panels = members[name]!
            let settings = defaults[name]
            guard settings?.isOpen ?? true else {
                layout.closedPanels.formUnion(panels)
                continue
            }
            let group = PanelGroup(
                id: PanelGroup.id(forName: name), name: Self.groupName(name, settings: settings), panels: panels,
                collapsed: settings?.isCollapsed ?? false
            )
            layout.insert(group, at: settings?.edge ?? edge, index: nil)
        }
        layout.normalize()
        return layout
    }

    // MARK: Views of the clusters

    /// The groups at each edge: a strip's row, or every group of the cluster docked at a side
    /// (column by column).  Setting it replaces them (a side edge's groups keep their columns).
    var docks: [DockEdge: [PanelGroup]] {
        get {
            var result = strips.filter { !$0.key.isVertical && !$0.value.isEmpty }
            for cluster in clusters { if let edge = cluster.edge { result[edge] = cluster.groups } }
            return result
        }
        set {
            for edge in DockEdge.allCases {
                if edge.isVertical { setDockedGroups(newValue[edge] ?? [], edge: edge) } else { strips[edge] = newValue[edge] }
            }
            normalize()
        }
    }

    /// Every group of every floating cluster, each with its cluster's frame and display.
    /// Setting it with the same groups in the same order changes their groups, frames and
    /// displays in place; anything else makes one floating cluster per entry.
    var floating: [FloatingGroup] {
        get {
            clusters.filter { $0.edge == nil }.flatMap { cluster in
                cluster.groups.map { FloatingGroup(group: $0, frame: cluster.frame ?? LayoutRect(x: 0, y: 0, width: cluster.width, height: 320), display: cluster.display) }
            }
        }
        set {
            let current = floating
            if newValue.map(\.group.id) == current.map(\.group.id) {
                for (entry, old) in zip(newValue, current) where entry != old {
                    update(group: entry.group.id) { $0 = entry.group }
                    if let index = clusterIndex(containing: entry.group.id), entry.frame != old.frame || entry.display != old.display {
                        clusters[index].frame = entry.frame
                        clusters[index].display = entry.display
                    }
                }
            } else {
                clusters.removeAll { $0.edge == nil }
                for entry in newValue {
                    clusters.append(.floating(entry.group, id: uniqueClusterID(entry.group.id), frame: entry.frame, display: entry.display))
                }
            }
            normalize()
        }
    }

    // MARK: Queries

    enum GroupLocation: Equatable, Sendable {
        /// At an edge: index among `docks[edge]`.
        case docked(DockEdge, Int)
        /// Floating: index among `floating`.
        case floating(Int)
    }

    /// Every group: docked left, right, top, bottom, then floating.
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

    /// The cluster `id`.
    func cluster(_ id: PanelCluster.ID) -> PanelCluster? { clusters.first { $0.id == id } }

    /// The cluster holding group `id` (nil for a strip's group).
    func cluster(containing id: PanelGroup.ID) -> PanelCluster? { clusterIndex(containing: id).map { clusters[$0] } }

    /// The cluster docked at `edge`.
    func dockedCluster(_ edge: DockEdge) -> PanelCluster? { dockedClusterIndex(edge).map { clusters[$0] } }

    var floatingClusters: [PanelCluster] { clusters.filter { $0.edge == nil } }

    func clusterIndex(containing id: PanelGroup.ID) -> Int? {
        clusters.firstIndex { $0.position(of: id) != nil }
    }

    func dockedClusterIndex(_ edge: DockEdge) -> Int? {
        clusters.firstIndex { $0.edge == edge }
    }

    /// The width a side edge's docked cluster takes (0 without one).
    func dockedWidth(_ edge: DockEdge) -> Double { dockedCluster(edge)?.width ?? 0 }

    /// A panel is visible when it is the front tab of an expanded group on a shown dock or
    /// floating.
    func isVisible(_ panel: PanelID) -> Bool {
        guard let group = group(containing: panel), !group.collapsed, group.effectiveActivePanel == panel,
            let location = location(of: group.id)
        else { return false }
        if case let .docked(edge, _) = location { return !hiddenDocks.contains(edge) }
        return true
    }

    /// The edge a group is docked at (a strip, or a docked cluster); nil when floating or unknown.
    func edge(of id: PanelGroup.ID) -> DockEdge? {
        if case let .docked(edge, _)? = location(of: id) { return edge }
        return nil
    }

    // MARK: Structure

    /// A cluster id not in use, `preferred` when free.
    func uniqueClusterID(_ preferred: String) -> String {
        clusters.contains { $0.id == preferred } ? UUID().uuidString : preferred
    }

    /// Keeps the structure tidy after every change: no empty columns or clusters, no empty strip
    /// entries, a floating cluster as wide as its columns, and each side edge's `dockWidth` equal
    /// to its docked cluster's edge column.
    mutating func normalize() {
        for edge in DockEdge.allCases where !edge.isVertical && strips[edge]?.isEmpty == true { strips[edge] = nil }
        for edge in DockEdge.allCases where edge.isVertical { strips[edge] = nil }
        for index in clusters.indices.reversed() {
            clusters[index].columns.removeAll { $0.groups.isEmpty }
            if clusters[index].columns.isEmpty {
                clusters.remove(at: index)
                continue
            }
            if clusters[index].edge == nil {
                let width = clusters[index].width
                clusters[index].frame?.width = width
            } else {
                clusters[index].frame = nil
                clusters[index].display = nil
            }
        }
        for cluster in clusters {
            if let edge = cluster.edge { dockWidth[edge] = cluster.columns[cluster.edgeColumnIndex].width }
        }
    }

    private enum GroupPath {
        case strip(DockEdge, Int)
        case cluster(Int, column: Int, index: Int)
    }

    private func path(of id: PanelGroup.ID) -> GroupPath? {
        for edge in DockEdge.allCases where !edge.isVertical {
            if let index = strips[edge]?.firstIndex(where: { $0.id == id }) { return .strip(edge, index) }
        }
        for (clusterIndex, cluster) in clusters.enumerated() {
            if let position = cluster.position(of: id) { return .cluster(clusterIndex, column: position.column, index: position.index) }
        }
        return nil
    }

    private mutating func update(group id: PanelGroup.ID, _ change: (inout PanelGroup) -> Void) {
        switch path(of: id) {
        case let .strip(edge, index): change(&strips[edge]![index])
        case let .cluster(cluster, column, index): change(&clusters[cluster].columns[column].groups[index])
        case nil: break
        }
    }

    /// Takes group `id` out of its strip or cluster.  A column left empty goes (a floating
    /// cluster losing its leftmost column keeps its other columns where they are); a cluster left
    /// empty goes.
    private mutating func extract(group id: PanelGroup.ID) -> PanelGroup? {
        switch path(of: id) {
        case let .strip(edge, index):
            return strips[edge]!.remove(at: index)
        case let .cluster(cluster, column, index):
            let group = clusters[cluster].columns[column].groups.remove(at: index)
            removeColumnIfEmpty(cluster: cluster, column: column)
            return group
        case nil:
            return nil
        }
    }

    private mutating func removeColumnIfEmpty(cluster: Int, column: Int) {
        guard clusters[cluster].columns[column].groups.isEmpty else { return }
        let removed = clusters[cluster].columns.remove(at: column)
        if clusters[cluster].columns.isEmpty {
            clusters.remove(at: cluster)
            return
        }
        if column == 0, clusters[cluster].edge == nil { clusters[cluster].frame?.x += removed.width + PanelCluster.columnDividerWidth }
        if clusters[cluster].edge == nil {
            let width = clusters[cluster].width
            clusters[cluster].frame?.width = width
        }
    }

    /// Puts `group` at `edge`: a strip's row, or a column of the cluster docked at a side (made
    /// when there is none, as wide as `dockWidth` says) -- its edge column unless `column` says.
    fileprivate mutating func insert(_ group: PanelGroup, at edge: DockEdge, index: Int?, column: Int? = nil) {
        guard edge.isVertical else {
            var list = strips[edge] ?? []
            list.insert(group, at: min(max(index ?? list.count, 0), list.count))
            strips[edge] = list
            return
        }
        if let cluster = dockedClusterIndex(edge) {
            let target = min(max(column ?? clusters[cluster].edgeColumnIndex, 0), clusters[cluster].columns.count - 1)
            var list = clusters[cluster].columns[target].groups
            list.insert(group, at: min(max(index ?? list.count, 0), list.count))
            clusters[cluster].columns[target].groups = list
        } else {
            let width = dockWidth[edge] ?? Self.defaultDockWidth[edge] ?? 280
            clusters.append(PanelCluster(id: uniqueClusterID(edge.rawValue), edge: edge, columns: [PanelColumn(groups: [group], width: width)]))
        }
    }

    /// Replaces the groups of the cluster docked at `edge` (the `docks` setter): groups that stay
    /// keep their column, new ones join the edge column.
    private mutating func setDockedGroups(_ groups: [PanelGroup], edge: DockEdge) {
        guard let index = dockedClusterIndex(edge) else {
            guard !groups.isEmpty else { return }
            let width = dockWidth[edge] ?? Self.defaultDockWidth[edge] ?? 280
            clusters.append(PanelCluster(id: uniqueClusterID(edge.rawValue), edge: edge, columns: [PanelColumn(groups: groups, width: width)]))
            return
        }
        guard !groups.isEmpty else {
            clusters.remove(at: index)
            return
        }
        var cluster = clusters[index]
        let columnOf = Dictionary(cluster.columns.enumerated().flatMap { column, entry in entry.groups.map { ($0.id, column) } }, uniquingKeysWith: { first, _ in first })
        for column in cluster.columns.indices { cluster.columns[column].groups = [] }
        for group in groups { cluster.columns[columnOf[group.id] ?? cluster.edgeColumnIndex].groups.append(group) }
        clusters[index] = cluster
    }

    private static func removing(_ panel: PanelID, from group: PanelGroup) -> PanelGroup? {
        var result = group
        result.panels.removeAll { $0 == panel }
        if result.panels.isEmpty { return nil }
        if result.activePanel == panel { result.activePanel = result.panels.first }
        return result
    }

    // MARK: Operations

    /// Takes `panel` out of the layout; a group left empty disappears.
    mutating func removePanel(_ panel: PanelID) {
        for edge in DockEdge.allCases where strips[edge] != nil {
            strips[edge] = strips[edge]!.compactMap { Self.removing(panel, from: $0) }
        }
        for cluster in clusters.indices {
            for column in clusters[cluster].columns.indices {
                clusters[cluster].columns[column].groups = clusters[cluster].columns[column].groups.compactMap { Self.removing(panel, from: $0) }
            }
            for column in clusters[cluster].columns.indices.reversed() where clusters[cluster].columns[column].groups.isEmpty && clusters[cluster].columns.count > 1 {
                removeColumnIfEmpty(cluster: cluster, column: column)
            }
        }
        normalize()
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
        normalize()
    }

    /// Splits `panel` into a new group docked at `edge` (drag onto the dock, New Panel Group).
    /// `index` is the position among the groups docked there before the move (in `column` of a
    /// docked cluster, its edge column unless given).
    @discardableResult
    mutating func movePanel(_ panel: PanelID, toNewGroupAt edge: DockEdge, index: Int? = nil, column: Int? = nil) -> PanelGroup.ID {
        var insertion = index
        if let index, let current = group(containing: panel), current.panels == [panel],
            case let .docked(currentEdge, currentIndex)? = location(of: current.id), currentEdge == edge, currentIndex < index
        {
            insertion = index - 1
        }
        let columns = dockedCluster(edge)?.columns.count
        removePanel(panel)
        let group = PanelGroup(panels: [panel])
        // A column the removal emptied has gone: fall back to the edge column.
        insert(group, at: edge, index: insertion, column: columns == dockedCluster(edge)?.columns.count ? column : nil)
        normalize()
        return group.id
    }

    /// Splits `panel` into a new floating group, a cluster of its own.
    @discardableResult
    mutating func floatPanel(_ panel: PanelID, frame: LayoutRect) -> PanelGroup.ID {
        removePanel(panel)
        let group = PanelGroup(panels: [panel])
        clusters.append(.floating(group, id: uniqueClusterID(group.id), frame: frame))
        normalize()
        return group.id
    }

    /// Float Group: the group floats on its own at `frame`, leaving its cluster (docked, or
    /// floating with other groups).  A group already floating alone stays where it is.
    mutating func float(group id: PanelGroup.ID, frame: LayoutRect) {
        if let cluster = cluster(containing: id), cluster.edge == nil, cluster.groups.count == 1 { return }
        guard path(of: id) != nil else { return }
        detach(group: id, frame: frame)
        update(group: id) { $0.collapsed = false }
        normalize()
    }

    /// Docks a group at `edge` (Dock Group, drag to the dock edge), from floating or another edge.
    mutating func dock(group id: PanelGroup.ID, at edge: DockEdge, index: Int? = nil, column: Int? = nil) {
        guard let group = extract(group: id) else { return }
        insert(group, at: edge, index: index, column: column)
        normalize()
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

    /// Moves or resizes the floating cluster holding group `id` (its window was moved or resized).
    mutating func setFrame(_ frame: LayoutRect, floatingGroup id: PanelGroup.ID) {
        guard let index = clusterIndex(containing: id), clusters[index].edge == nil else { return }
        setFrame(frame, cluster: clusters[index].id)
    }

    /// Moves or resizes floating cluster `id`.  A change of width goes to its last column (its
    /// window keeps that column at least `PanelCluster.minimumColumnWidth` wide).
    mutating func setFrame(_ frame: LayoutRect, cluster id: PanelCluster.ID) {
        guard let index = clusters.firstIndex(where: { $0.id == id }), clusters[index].edge == nil else { return }
        let delta = frame.width - clusters[index].width
        if abs(delta) > 0.001, let last = clusters[index].columns.indices.last {
            clusters[index].columns[last].width = max(1, clusters[index].columns[last].width + delta)
        }
        clusters[index].frame = frame
        normalize()
    }

    /// The width of a side edge's docked cluster's column beside the canvas (the dock handle), or
    /// a strip's height.
    mutating func setDockWidth(_ width: Double, edge: DockEdge) {
        let width = max(Self.minimumDockWidth, width)
        if edge.isVertical, let index = dockedClusterIndex(edge) {
            clusters[index].columns[clusters[index].innerColumnIndex].width = width
        } else {
            dockWidth[edge] = width
        }
        normalize()
    }

    /// Column `column` of cluster `id` becomes `width` points wide (a column divider's drag).
    mutating func setColumnWidth(_ width: Double, cluster id: PanelCluster.ID, column: Int) {
        guard let index = clusters.firstIndex(where: { $0.id == id }), clusters[index].columns.indices.contains(column) else { return }
        clusters[index].columns[column].width = max(PanelCluster.minimumColumnWidth, width)
        normalize()
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
        closedPanels.formIntersection(registered)
    }

    /// Adds panels the layout does not have yet to their default group, creating the group at
    /// its default edge (else `edge`) when it does not exist.  Called after loading, so a panel
    /// a later task registers appears without a reset.  Closed panels stay closed; a panel whose
    /// default group is closed by default joins them.
    mutating func add(panels descriptors: [PanelDescriptor], groups defaults: [String: PanelGroupDefaults] = [:], edge: DockEdge = .right) {
        for descriptor in descriptors where !contains(descriptor.id) && !closedPanels.contains(descriptor.id) {
            let settings = defaults[descriptor.defaultGroup]
            if settings?.isOpen == false {
                closedPanels.insert(descriptor.id)
                continue
            }
            place(descriptor, settings: settings, edge: edge)
        }
        normalize()
    }

    private mutating func place(_ descriptor: PanelDescriptor, settings: PanelGroupDefaults?, edge: DockEdge) {
        let defaultID = PanelGroup.id(forName: descriptor.defaultGroup)
        if group(defaultID) != nil {
            update(group: defaultID) { $0.panels.append(descriptor.id) }
        } else if let named = groups.first(where: { $0.name == descriptor.defaultGroup }) {
            update(group: named.id) { $0.panels.append(descriptor.id) }
        } else {
            let name = Self.groupName(descriptor.defaultGroup, settings: settings)
            insert(PanelGroup(id: defaultID, name: name, panels: [descriptor.id]), at: settings?.edge ?? edge, index: nil)
        }
    }

    /// A default group's stored name: nil (named after its panels) unless it keeps its name;
    /// groups without settings keep theirs.
    static func groupName(_ name: String, settings: PanelGroupDefaults?) -> String? {
        guard let settings else { return name }
        return settings.keepsName ? name : nil
    }

    /// Brings closed panels back (menu:Window[<panel>] on a closed panel): each of
    /// `descriptors` rejoins its default group, recreated at its default edge if needed.
    mutating func reopen(_ descriptors: [PanelDescriptor], groups defaults: [String: PanelGroupDefaults] = [:], edge: DockEdge = .right) {
        for descriptor in descriptors where !contains(descriptor.id) {
            closedPanels.remove(descriptor.id)
            place(descriptor, settings: defaults[descriptor.defaultGroup], edge: edge)
        }
        normalize()
    }

    /// Close Group: the group's panels leave the layout and stay closed until shown again.
    mutating func close(group id: PanelGroup.ID) {
        guard let group = group(id) else { return }
        for panel in group.panels { removePanel(panel) }
        closedPanels.formUnion(group.panels)
    }

    /// Moves every panel of group `source` into group `target` (a group dragged onto a tab
    /// strip), the first moved panel in front.
    mutating func merge(group source: PanelGroup.ID, into target: PanelGroup.ID) {
        guard source != target, let moving = group(source), group(target) != nil else { return }
        for panel in moving.panels { movePanel(panel, toGroup: target) }
        activate(moving.panels[0])
    }

    /// Moves floating clusters whose frame is off every display onto `screen`.
    mutating func moveOffscreenFloatingGroups(onto screen: LayoutRect) {
        for index in clusters.indices where clusters[index].edge == nil {
            guard let frame = clusters[index].frame, !frame.intersects(screen) else { continue }
            clusters[index].frame?.x = screen.x + 40
            clusters[index].frame?.y = screen.maxY - frame.height - 40
            clusters[index].display = nil
        }
    }

    // MARK: Clusters (D-077, magnetic panels)

    /// Pulls group `id` out of its cluster (Option-drag, Float Group) into a floating cluster of
    /// its own at `frame`, and returns that cluster's id.  The only group of a floating cluster
    /// just moves; the only group of a docked cluster undocks it.
    @discardableResult
    mutating func detach(group id: PanelGroup.ID, frame: LayoutRect) -> PanelCluster.ID? {
        if let index = clusterIndex(containing: id), clusters[index].groups.count == 1 {
            let clusterID = clusters[index].id
            clusters[index].edge = nil
            clusters[index].columns[0].width = frame.width
            clusters[index].frame = frame
            normalize()
            return clusterID
        }
        guard let group = extract(group: id) else { return nil }
        let clusterID = uniqueClusterID(group.id)
        clusters.append(.floating(group, id: clusterID, frame: frame))
        normalize()
        return clusterID
    }

    /// A docked cluster floats at `frame` (dragging it off its edge).
    mutating func undock(cluster id: PanelCluster.ID, frame: LayoutRect) {
        guard let index = clusters.firstIndex(where: { $0.id == id }), clusters[index].edge != nil else { return }
        clusters[index].edge = nil
        clusters[index].frame = frame
        normalize()
    }

    /// Cluster `id` joins what it was dropped on (`PanelSnapping`): it docks at a free window
    /// edge, becomes columns beside another cluster, joins one of its columns, merges into a
    /// group's tabs, or joins a strip.
    mutating func attach(cluster id: PanelCluster.ID, to target: PanelSnapTarget) {
        guard let index = clusters.firstIndex(where: { $0.id == id }) else { return }
        let moving = clusters[index]
        switch target {
        case let .dock(edge):
            guard edge.isVertical else { return }
            if let docked = dockedClusterIndex(edge), docked != index {
                // The edge is taken: the columns go on its outer side.
                clusters.remove(at: index)
                let host = dockedClusterIndex(edge)!
                let at = edge == .right ? clusters[host].columns.count : 0
                clusters[host].columns.insert(contentsOf: moving.columns, at: at)
            } else {
                clusters[index].edge = edge
            }
        case let .column(targetID, at):
            guard targetID != id, clusters.contains(where: { $0.id == targetID }) else { return }
            clusters.remove(at: index)
            let host = clusters.firstIndex { $0.id == targetID }!
            let position = min(max(at, 0), clusters[host].columns.count)
            clusters[host].columns.insert(contentsOf: moving.columns, at: position)
            if position == 0, clusters[host].edge == nil {
                // Beside it on the left: the host stays where it is.
                clusters[host].frame?.x -= moving.width + PanelCluster.columnDividerWidth
            }
        case let .stack(targetID, column, at):
            guard targetID != id, let host = clusters.firstIndex(where: { $0.id == targetID }), clusters[host].columns.indices.contains(column) else { return }
            let groups = moving.groups
            let position = min(max(at, 0), clusters[host].columns[column].groups.count)
            clusters[host].columns[column].groups.insert(contentsOf: groups, at: position)
            if clusters[host].edge == nil, position == 0, let frame = clusters[host].frame, let movingFrame = moving.frame {
                // Stacked on top: the cluster grows upwards, its bottom stays.
                clusters[host].frame?.height = frame.height + movingFrame.height
            } else if clusters[host].edge == nil, let movingFrame = moving.frame {
                // Stacked below: the cluster grows downwards, its top stays.
                clusters[host].frame?.y -= movingFrame.height
                clusters[host].frame?.height += movingFrame.height
            }
            clusters.remove(at: clusters.firstIndex { $0.id == id }!)
        case let .merge(groupID):
            guard moving.groups.count == 1, moving.position(of: groupID) == nil else { return }
            merge(group: moving.groups[0].id, into: groupID)
        case let .strip(edge, at):
            guard !edge.isVertical else { return }
            clusters.remove(at: index)
            var list = strips[edge] ?? []
            list.insert(contentsOf: moving.groups, at: min(max(at, 0), list.count))
            strips[edge] = list
        }
        normalize()
    }
}
