import AppKit
import Foundation
import Testing
@testable import WireTuner

/// Clusters in the layout (D-077, magnetic panels): pulling groups out, docking, joining, and the
/// saved form with its migration from version 1 files.
@Suite @MainActor struct PanelClusterLayoutTests {
    private let descriptors = ["object", "document", "layers", "swatches", "tools"].map { id in
        PanelDescriptor(id: PanelID(rawValue: id), title: id.capitalized, defaultGroup: id == "document" ? "Object" : id.capitalized, menuOrder: 0) { NSView() }
    }

    /// Object/Document and Layers and Swatches docked right, Tools docked left.
    private var standard: PanelLayout {
        PanelLayout.standard(for: descriptors, groups: ["Tools": PanelGroupDefaults(position: 0, edge: .left)])
    }

    @Test func theFactoryLayoutIsADockedClusterAtEachEdge() throws {
        let layout = standard
        #expect(layout.clusters.count == 2)
        let right = try #require(layout.dockedCluster(.right))
        #expect(right.id == "right" && right.columns.count == 1 && right.columns[0].width == 280)
        #expect(right.groups.map(\.id) == ["object", "layers", "swatches"])
        #expect(layout.dockedCluster(.left)?.groups.map(\.id) == ["tools"] && layout.dockedCluster(.left)?.columns[0].width == 84)
        #expect(layout.floatingClusters.isEmpty && layout.dockedWidth(.right) == 280 && layout.dockedWidth(.top) == 0)
        #expect(layout.docks[.right]?.map(\.id) == ["object", "layers", "swatches"], "the edge's groups, as before")
    }

    @Test func optionDragsDetachOneGroupAndPlainDragsUndockTheCluster() throws {
        var layout = standard
        let frame = LayoutRect(x: 500, y: 300, width: 280, height: 220)
        let pulled = layout.detach(group: "layers", frame: frame)
        let detached = try #require(pulled)
        #expect(detached == "layers")
        #expect(layout.cluster("layers")?.frame == frame && layout.cluster("layers")?.edge == nil)
        #expect(layout.dockedCluster(.right)?.groups.map(\.id) == ["object", "swatches"])
        // The whole docked cluster floats, groups and all.
        layout.undock(cluster: "right", frame: LayoutRect(x: 900, y: 0, width: 280, height: 780))
        #expect(layout.dockedCluster(.right) == nil && layout.cluster("right")?.groups.map(\.id) == ["object", "swatches"])
        #expect(layout.cluster("right")?.frame == LayoutRect(x: 900, y: 0, width: 280, height: 780))
        #expect(layout.edge(of: "object") == nil && layout.location(of: "object") == .floating(0))
        // The only group of a cluster just moves it.
        #expect(layout.detach(group: "layers", frame: LayoutRect(x: 10, y: 10, width: 200, height: 200)) == "layers")
        #expect(layout.cluster("layers")?.columns[0].width == 200)
        // Undocking a floating cluster does nothing; an unknown group detaches nothing.
        let before = layout
        layout.undock(cluster: "layers", frame: frame)
        #expect(layout == before && layout.detach(group: "nope", frame: frame) == nil)
    }

    @Test func aDraggedClusterDocksAtAFreeEdgeOrBesideTheDockedOne() throws {
        var layout = standard
        layout.detach(group: "layers", frame: LayoutRect(x: 500, y: 300, width: 260, height: 220))
        layout.detach(group: "tools", frame: LayoutRect(x: 50, y: 300, width: 84, height: 400))
        #expect(layout.dockedCluster(.left) == nil)
        layout.attach(cluster: "left", to: .dock(.left))
        #expect(layout.dockedCluster(.left)?.groups.map(\.id) == ["tools"] && layout.cluster("left")?.frame == nil)
        // The right edge is taken: docking there puts the columns on its outer side.
        layout.attach(cluster: "layers", to: .dock(.right))
        let right = try #require(layout.dockedCluster(.right))
        #expect(right.columns.map { $0.groups.map(\.id) } == [["object", "swatches"], ["layers"]])
        #expect(right.edgeColumnIndex == 1 && right.innerColumnIndex == 0)
        #expect(layout.dockWidth[.right] == 260, "the edge column's width")
        #expect(right.width == 280 + 260 + PanelCluster.columnDividerWidth)
        // The handle resizes the column beside the canvas.
        layout.setDockWidth(300, edge: .right)
        #expect(layout.dockedCluster(.right)?.columns[0].width == 300 && layout.dockWidth[.right] == 260)
        layout.setColumnWidth(10, cluster: "right", column: 1)
        #expect(layout.dockedCluster(.right)?.columns[1].width == PanelCluster.minimumColumnWidth)
        // Beside it on the canvas side.
        layout.detach(group: "swatches", frame: LayoutRect(x: 400, y: 300, width: 240, height: 200))
        layout.attach(cluster: "swatches", to: .column(cluster: "right", index: 0))
        #expect(layout.dockedCluster(.right)?.columns.map { $0.groups.map(\.id) } == [["swatches"], ["object"], ["layers"]])
        #expect(layout.cluster("swatches") == nil)
    }

    @Test func floatingClustersJoinBesideAboveAndBelow() throws {
        var layout = standard
        layout.detach(group: "layers", frame: LayoutRect(x: 500, y: 300, width: 260, height: 220))
        layout.detach(group: "swatches", frame: LayoutRect(x: 100, y: 300, width: 200, height: 220))
        // Beside it on the left: Layers stays where it is, the cluster grows leftwards.
        layout.attach(cluster: "swatches", to: .column(cluster: "layers", index: 0))
        var cluster = try #require(layout.cluster("layers"))
        #expect(cluster.columns.map { $0.groups.map(\.id) } == [["swatches"], ["layers"]])
        #expect(cluster.frame == LayoutRect(x: 500 - 200 - PanelCluster.columnDividerWidth, y: 300, width: 200 + 260 + PanelCluster.columnDividerWidth, height: 220))
        // Stacked on top of a column: the cluster grows upwards.
        // Object is the docked cluster's last group: detaching it floats that cluster.
        let pulled = layout.detach(group: "object", frame: LayoutRect(x: 0, y: 0, width: 260, height: 180))
        let object = try #require(pulled)
        #expect(object == "right")
        layout.attach(cluster: object, to: .stack(cluster: "layers", column: 1, index: 0))
        cluster = try #require(layout.cluster("layers"))
        #expect(cluster.columns[1].groups.map(\.id) == ["object", "layers"] && cluster.frame?.y == 300 && cluster.frame?.height == 400)
        // Stacked below: it grows downwards, its top stays.
        layout.detach(group: "tools", frame: LayoutRect(x: 0, y: 0, width: 84, height: 100))
        layout.attach(cluster: "left", to: .stack(cluster: "layers", column: 0, index: 5))
        cluster = try #require(layout.cluster("layers"))
        #expect(cluster.columns[0].groups.map(\.id) == ["swatches", "tools"] && cluster.frame?.y == 200 && cluster.frame?.maxY == 700)
        // Pulling the left column's only groups out keeps the other columns where they are.
        let right = cluster.frame!.maxX
        layout.float(group: "swatches", frame: LayoutRect(x: 0, y: 0, width: 200, height: 200))
        layout.float(group: "tools", frame: LayoutRect(x: 0, y: 0, width: 84, height: 200))
        cluster = try #require(layout.cluster("layers"))
        #expect(cluster.columns.count == 1 && cluster.frame?.maxX == right && cluster.frame?.width == 260)
        // A cluster cannot join itself; unknown targets do nothing.
        let before = layout
        layout.attach(cluster: "layers", to: .column(cluster: "layers", index: 0))
        layout.attach(cluster: "layers", to: .stack(cluster: "nope", column: 0, index: 0))
        layout.attach(cluster: "nope", to: .dock(.left))
        layout.attach(cluster: "layers", to: .dock(.top))
        layout.attach(cluster: "layers", to: .strip(.left, index: 0))
        #expect(layout == before)
    }

    @Test func aLoneGroupMergesAndStripsTakeGroups() throws {
        var layout = standard
        layout.detach(group: "layers", frame: LayoutRect(x: 500, y: 300, width: 260, height: 220))
        layout.attach(cluster: "layers", to: .merge(group: "object"))
        #expect(layout.group("object")?.panels == ["object", "document", "layers"] && layout.cluster("layers") == nil)
        layout.detach(group: "swatches", frame: LayoutRect(x: 500, y: 300, width: 260, height: 220))
        layout.attach(cluster: "swatches", to: .strip(.top, index: .max))
        #expect(layout.docks[.top]?.map(\.id) == ["swatches"] && layout.edge(of: "swatches") == .top)
        // A strip's group dragged away floats in a cluster of its own.
        #expect(layout.detach(group: "swatches", frame: LayoutRect(x: 1, y: 2, width: 3, height: 4)) == "swatches")
        #expect(layout.docks[.top] == nil && layout.strips.isEmpty)
    }

    @Test func floatGroupLeavesItsClusterAndTheOptionsMenuOffersIt() throws {
        var layout = standard
        layout.detach(group: "layers", frame: LayoutRect(x: 500, y: 300, width: 260, height: 220))
        layout.detach(group: "swatches", frame: LayoutRect(x: 100, y: 300, width: 200, height: 220))
        layout.attach(cluster: "swatches", to: .stack(cluster: "layers", column: 0, index: 1))
        let registry = PanelRegistry()
        for descriptor in descriptors { registry.registerIfAbsent(descriptor) }
        let clustered = PanelOption.menu(for: "swatches", layout: layout, registry: registry).tail
        #expect(clustered == [.rename, .float, .dock, .close], "a floating group clicked to others can float on its own")
        layout.setCollapsed(true, group: "swatches")
        layout.float(group: "swatches", frame: LayoutRect(x: 9, y: 9, width: 200, height: 200))
        #expect(layout.cluster(containing: "swatches")?.groups.count == 1 && layout.group("swatches")?.collapsed == false)
        #expect(PanelOption.menu(for: "swatches", layout: layout, registry: registry).tail == [.rename, .dock, .close])
        // Floating alone already: nothing changes.
        let before = layout
        layout.float(group: "swatches", frame: LayoutRect(x: 0, y: 0, width: 1, height: 1))
        #expect(layout == before)
    }

    @Test func resizingAFloatingClusterWidensItsLastColumn() throws {
        var layout = standard
        layout.detach(group: "layers", frame: LayoutRect(x: 500, y: 300, width: 260, height: 220))
        layout.detach(group: "swatches", frame: LayoutRect(x: 100, y: 300, width: 200, height: 220))
        layout.attach(cluster: "swatches", to: .column(cluster: "layers", index: 1))
        let width = try #require(layout.cluster("layers")?.width)
        layout.setFrame(LayoutRect(x: 500, y: 300, width: width + 40, height: 300), cluster: "layers")
        #expect(layout.cluster("layers")?.columns.map(\.width) == [260, 240] && layout.cluster("layers")?.frame?.height == 300)
        layout.setFrame(LayoutRect(x: 0, y: 0, width: 10, height: 10), floatingGroup: "object")
        #expect(layout.dockedCluster(.right)?.frame == nil, "a docked cluster has no frame")
    }

    @Test func removingPanelsTidiesColumnsAndClusters() throws {
        var layout = standard
        layout.detach(group: "layers", frame: LayoutRect(x: 500, y: 300, width: 260, height: 220))
        layout.detach(group: "swatches", frame: LayoutRect(x: 100, y: 300, width: 200, height: 220))
        layout.attach(cluster: "swatches", to: .column(cluster: "layers", index: 0))
        layout.removePanel("swatches")
        let cluster = try #require(layout.cluster("layers"))
        #expect(cluster.columns.count == 1 && cluster.frame?.x == 500 && cluster.frame?.width == 260)
        layout.close(group: "layers")
        #expect(layout.cluster("layers") == nil && layout.closedPanels.contains("layers"))
        // The docks setter keeps each group's column.
        let pulled = layout.detach(group: "object", frame: LayoutRect(x: 0, y: 0, width: 200, height: 200))
        let object = try #require(pulled)
        layout.attach(cluster: object, to: .dock(.right))
        var docks = layout.docks
        docks[.right]?.append(PanelGroup(id: "extra", panels: ["x"]))
        layout.docks = docks
        #expect(layout.dockedCluster(.right)?.columns.map { $0.groups.map(\.id) } == [["object", "extra"]])
        docks[.right] = []
        layout.docks = docks
        #expect(layout.dockedCluster(.right) == nil)
    }

    // MARK: Saved form

    @Test func clustersRoundTripThroughJSON() throws {
        var layout = standard
        layout.detach(group: "layers", frame: LayoutRect(x: 1200, y: 300, width: 260, height: 480))
        layout.detach(group: "swatches", frame: LayoutRect(x: 900, y: 300, width: 240, height: 480))
        layout.attach(cluster: "swatches", to: .column(cluster: "layers", index: 1))
        layout.clusters[layout.clusters.firstIndex { $0.id == "layers" }!].display = "display-1"
        layout.setDockWidth(300, edge: .right)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(layout)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"version\":2"))
        #expect(text.contains("\"clusters\":["))
        #expect(text.contains("\"edge\":\"right\""))
        #expect(text.contains("\"frame\":[1200,300,505,480]"))
        #expect(text.contains("\"display\":\"display-1\""))
        #expect(!text.contains("\"floating\""), "floating groups live in clusters now")
        #expect(try JSONDecoder().decode(PanelLayout.self, from: data) == layout)
    }

    @Test func aVersionOneLayoutMigratesToClusters() throws {
        let sample = """
        {
          "version": 1,
          "docks": {
            "right": [ { "name": "Properties", "panels": ["object", "document"], "height": 420 }, { "name": "Layers", "panels": ["layers"] } ],
            "left":  [ { "name": "Tools", "panels": ["tools"] } ],
            "top":   [ { "name": "Text", "panels": ["toolbar.text"] } ]
          },
          "floating": [
            { "name": "Swatches", "panels": ["swatches"], "frame": [1200, 300, 260, 480], "display": "<uuid>" },
            { "name": "Mixer", "panels": ["colorMixer"], "frame": [100, 100, 240, 300] }
          ],
          "dockWidth": { "right": 300, "left": 90 },
          "hiddenDocks": ["left"]
        }
        """
        let layout = try JSONDecoder().decode(PanelLayout.self, from: Data(sample.utf8))
        #expect(layout.version == PanelLayout.currentVersion)
        // Docked groups -> the cluster at that edge, at the edge's width.
        let right = try #require(layout.dockedCluster(.right))
        #expect(right.id == "right" && right.columns.count == 1 && right.columns[0].width == 300)
        #expect(right.groups.map(\.id) == ["properties", "layers"] && right.groups[0].height == 420)
        #expect(layout.dockedCluster(.left)?.groups.map(\.id) == ["tools"] && layout.dockedCluster(.left)?.columns[0].width == 90)
        #expect(layout.hiddenDocks == [.left] && layout.docks[.top]?.map(\.id) == ["text"])
        // Floating groups -> a floating cluster each.
        let floating = layout.floatingClusters
        #expect(floating.map(\.id) == ["swatches", "mixer"])
        #expect(floating[0].frame == LayoutRect(x: 1200, y: 300, width: 260, height: 480) && floating[0].display == "<uuid>")
        #expect(floating[1].columns[0].width == 240 && floating[1].display == nil)
        #expect(layout.floating.map(\.group.id) == ["swatches", "mixer"])
        // Written back, it is a version 2 file that reads the same.
        let again = try JSONDecoder().decode(PanelLayout.self, from: JSONEncoder().encode(layout))
        #expect(again == layout)
        // A future version is left alone for the store to refuse.
        let future = try JSONDecoder().decode(PanelLayout.self, from: Data("{\"version\": 9}".utf8))
        #expect(future.version == 9)
    }

    @Test func theStoreMigratesAnOldFileOnLoad() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "snp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"version\":1,\"docks\":{\"right\":[{\"name\":\"Layers\",\"panels\":[\"layers\"]}]}}".utf8).write(to: url)
        let store = PanelLayoutStore(url: url)
        let loaded = try #require(try store.load())
        #expect(loaded.dockedCluster(.right)?.groups.map(\.id) == ["layers"] && loaded.version == 2)
        try store.save(loaded)
        #expect(try store.load() == loaded)
    }

    @Test func offscreenFloatingClustersMoveOntoTheMainDisplay() {
        var layout = standard
        layout.detach(group: "layers", frame: LayoutRect(x: -5000, y: 0, width: 260, height: 300))
        layout.clusters[layout.clusters.firstIndex { $0.id == "layers" }!].display = "gone"
        layout.moveFloatingGroups(onto: LayoutRect(x: 0, y: 0, width: 1440, height: 900), displays: ["main"], screens: [LayoutRect(x: 0, y: 0, width: 1440, height: 900)])
        #expect(layout.cluster("layers")?.frame == LayoutRect(x: 40, y: 900 - 300 - 40, width: 260, height: 300) && layout.cluster("layers")?.display == nil)
        layout.detach(group: "swatches", frame: LayoutRect(x: 9000, y: 0, width: 260, height: 300))
        layout.moveOffscreenFloatingGroups(onto: LayoutRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(layout.cluster("swatches")?.frame?.x == 40)
    }
}
