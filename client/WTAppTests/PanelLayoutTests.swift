import AppKit
import Foundation
import Testing
@testable import WireTuner

@Suite struct PanelLayoutTests {
    private let object = PlaceholderPanels.object
    private let layers = PlaceholderPanels.layers
    private let document = PanelDescriptor(id: "document", title: "Document", defaultGroup: "Properties", menuOrder: 11) { NSView() }
    private let swatches = PanelDescriptor(id: "swatches", title: "Swatches", defaultGroup: "Assets", menuOrder: 30) { NSView() }

    private var standard: PanelLayout { PanelLayout.standard(for: [object, document, layers]) }

    @Test func standardLayoutGroupsByDefaultGroup() {
        let layout = standard
        #expect(layout.version == PanelLayout.currentVersion)
        #expect(layout.docks[.right]?.map(\.id) == ["properties", "layers"])
        #expect(layout.docks[.right]?[0] == PanelGroup(id: "properties", name: "Properties", panels: ["object", "document"], activePanel: "object"))
        #expect(layout.docks[.left] == nil)
        #expect(layout.floating.isEmpty)
        #expect(layout.dockWidth == PanelLayout.defaultDockWidth)
        #expect(layout.hiddenDocks.isEmpty)
        #expect(layout.panelIDs == ["object", "document", "layers"])
        #expect(PanelLayout.standard(for: []).docks.isEmpty)
        #expect(PanelGroup.id(forName: "Mixer and Tints") == "mixer-and-tints")
    }

    @Test func queriesLocateGroupsAndPanels() {
        var layout = standard
        #expect(layout.location(of: "layers") == .docked(.right, 1))
        #expect(layout.location(of: "nope") == nil)
        #expect(layout.group("nope") == nil)
        #expect(layout.group(containing: "document")?.id == "properties")
        #expect(layout.group(containing: "nope") == nil)
        #expect(layout.contains("layers"))
        #expect(layout.isVisible("object"))
        #expect(!layout.isVisible("document"))
        #expect(!layout.isVisible("nope"))
        layout.floatPanel("layers", frame: LayoutRect(x: 0, y: 0, width: 200, height: 300))
        #expect(layout.location(of: layout.group(containing: "layers")!.id) == .floating(0))
        #expect(layout.isVisible("layers"))
        #expect(layout.groups.count == 2)
    }

    @Test func movesPanelsBetweenGroups() {
        var layout = standard
        layout.movePanel("layers", toGroup: "properties")
        #expect(layout.docks[.right]?.map(\.id) == ["properties"])
        #expect(layout.group("properties")?.panels == ["object", "document", "layers"])
        #expect(layout.group("properties")?.activePanel == "layers")

        layout.movePanel("object", toGroup: "properties", at: 0)
        #expect(layout.group("properties")?.panels == ["object", "document", "layers"])
        #expect(layout.group("properties")?.activePanel == "object")

        layout.movePanel("layers", toGroup: "missing")
        #expect(layout == {
            var expected = standard
            expected.movePanel("layers", toGroup: "properties")
            expected.movePanel("object", toGroup: "properties", at: 0)
            return expected
        }())

        let id = layout.movePanel("layers", toNewGroupAt: .right, index: 0)
        #expect(layout.docks[.right]?.map(\.id) == [id, "properties"])
        layout.setCollapsed(true, group: id)
        layout.movePanel("layers", toGroup: id)
        #expect(layout.group(id)?.collapsed == false)
        #expect(layout.group(id)?.panels == ["layers"])
    }

    @Test func splittingAdjustsForTheVacatedGroup() {
        var layout = standard
        layout.movePanel("layers", toNewGroupAt: .right, index: 5)
        #expect(layout.docks[.right]?.count == 2)
        #expect(layout.docks[.right]?[1].panels == ["layers"])
        #expect(layout.docks[.right]?[1].id != "layers")

        var toLeft = standard
        let left = toLeft.movePanel("object", toNewGroupAt: .left, index: 0)
        #expect(toLeft.docks[.left]?.map(\.id) == [left])
        #expect(toLeft.group("properties")?.panels == ["document"])
        #expect(toLeft.group("properties")?.activePanel == "document")

        var above = standard
        above.movePanel("layers", toGroup: "properties")
        above.movePanel("document", toNewGroupAt: .right, index: 0)
        let first = above.docks[.right]![0].id
        above.movePanel("document", toNewGroupAt: .right, index: 2)
        #expect(above.docks[.right]?.map(\.id) == ["properties", above.docks[.right]![1].id])
        #expect(above.docks[.right]?[1].id != first)
        above.movePanel("document", toNewGroupAt: .right)
        #expect(above.docks[.right]?.count == 2)
    }

    @Test func floatsAndDocksGroups() {
        var layout = standard
        let frame = LayoutRect(x: 100, y: 100, width: 260, height: 480)
        layout.setCollapsed(true, group: "layers")
        layout.float(group: "layers", frame: frame)
        #expect(layout.docks[.right]?.map(\.id) == ["properties"])
        #expect(layout.floating == [FloatingGroup(group: PanelGroup(id: "layers", name: "Layers", panels: ["layers"]), frame: frame)])
        layout.float(group: "layers", frame: frame)
        layout.float(group: "missing", frame: frame)
        #expect(layout.floating.count == 1)

        layout.setFrame(LayoutRect(x: 1, y: 2, width: 3, height: 4), floatingGroup: "layers")
        #expect(layout.floating[0].frame == LayoutRect(x: 1, y: 2, width: 3, height: 4))
        layout.setFrame(frame, floatingGroup: "properties")

        layout.dock(group: "layers", at: .right, index: 0)
        #expect(layout.docks[.right]?.map(\.id) == ["layers", "properties"])
        #expect(layout.floating.isEmpty)
        layout.dock(group: "layers", at: .left)
        #expect(layout.docks[.left]?.map(\.id) == ["layers"])
        #expect(layout.docks[.right]?.map(\.id) == ["properties"])
        layout.dock(group: "missing", at: .left)
        #expect(layout.groups.count == 2)

        let floated = layout.floatPanel("object", frame: frame)
        #expect(layout.location(of: floated) == .floating(0))
        layout.removePanel("object")
        #expect(layout.floating.isEmpty)
        layout.removePanel("nothing")
    }

    @Test func collapsesActivatesAndReorders() {
        var layout = standard
        layout.toggleCollapsed(group: "properties")
        #expect(layout.group("properties")?.collapsed == true)
        #expect(!layout.isVisible("object"))
        layout.setDockHidden(true, edge: .right)
        layout.activate("document")
        #expect(layout.group("properties")?.collapsed == false)
        #expect(layout.group("properties")?.activePanel == "document")
        #expect(layout.hiddenDocks.isEmpty)
        #expect(layout.isVisible("document"))
        layout.activate("missing")
        layout.toggleCollapsed(group: "missing")

        layout.reorderPanel("document", to: 0)
        #expect(layout.group("properties")?.panels == ["document", "object"])
        layout.reorderPanel("document", to: 99)
        #expect(layout.group("properties")?.panels == ["object", "document"])
        layout.reorderPanel("missing", to: 0)

        layout.rename(group: "properties", to: "Mine")
        #expect(layout.group("properties")?.name == "Mine")
        layout.rename(group: "properties", to: "")
        #expect(layout.group("properties")?.name == "Mine")
        layout.rename(group: "properties", to: nil)
        #expect(layout.group("properties")?.displayName(titles: { $0.rawValue.capitalized }) == "Object / Document")
        layout.setHeight(300, group: "properties")
        #expect(layout.group("properties")?.height == 300)
    }

    @Test func docksHideAndResize() {
        var layout = standard
        layout.toggleDockHidden(.right)
        #expect(layout.hiddenDocks == [.right])
        #expect(!layout.isVisible("object"))
        layout.toggleDockHidden(.right)
        #expect(layout.hiddenDocks.isEmpty)
        layout.setDockWidth(10, edge: .right)
        #expect(layout.dockWidth[.right] == PanelLayout.minimumDockWidth)
        layout.setDockWidth(320, edge: .left)
        #expect(layout.dockWidth[.left] == 320)
    }

    @Test func prunesAndAddsPanels() {
        var layout = standard
        layout.prune(keeping: ["object", "layers"])
        #expect(layout.panelIDs == ["object", "layers"])
        layout.prune(keeping: ["layers"])
        #expect(layout.docks[.right]?.map(\.id) == ["layers"])

        layout.add(panels: [object, document, swatches, layers])
        #expect(layout.docks[.right]?.map(\.id) == ["layers", "properties", "assets"])
        #expect(layout.group("properties")?.panels == ["object", "document"])
        #expect(layout.group("assets")?.panels == ["swatches"])

        var renamed = standard
        renamed.rename(group: "properties", to: "Props")
        renamed.movePanel("object", toNewGroupAt: .right)
        let custom = PanelDescriptor(id: "extra", title: "Extra", defaultGroup: "Props") { NSView() }
        renamed.add(panels: [custom])
        #expect(renamed.group("properties")?.panels == ["document", "extra"])
    }

    @Test func movesOffscreenFloatingGroups() {
        var layout = standard
        let screen = LayoutRect(x: 0, y: 0, width: 1440, height: 900)
        layout.floatPanel("layers", frame: LayoutRect(x: 3000, y: 100, width: 260, height: 480))
        layout.floating[0].display = "gone"
        layout.floatPanel("document", frame: LayoutRect(x: 100, y: 100, width: 260, height: 480))
        layout.moveOffscreenFloatingGroups(onto: screen)
        #expect(layout.floating[0].frame == LayoutRect(x: 40, y: 900 - 480 - 40, width: 260, height: 480))
        #expect(layout.floating[0].display == nil)
        #expect(layout.floating[1].frame == LayoutRect(x: 100, y: 100, width: 260, height: 480))
        #expect(LayoutRect(x: 0, y: 0, width: 10, height: 10).intersects(LayoutRect(x: 5, y: 5, width: 10, height: 10)))
        #expect(!LayoutRect(x: 0, y: 0, width: 10, height: 10).intersects(LayoutRect(x: 10, y: 0, width: 10, height: 10)))
    }

    @Test func roundTripsThroughJSON() throws {
        var layout = standard
        layout.float(group: "layers", frame: LayoutRect(x: 1200, y: 300, width: 260, height: 480))
        layout.floating[0].display = "display-1"
        layout.setCollapsed(true, group: "properties")
        layout.setHeight(420, group: "properties")
        layout.setDockHidden(true, edge: .left)
        layout.setDockWidth(300, edge: .right)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(layout)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"frame\":[1200,300,260,480]"))
        #expect(text.contains("\"docks\":{\"right\":[{\"active\":\"object\",\"collapsed\":true,\"height\":420,\"id\":\"properties\",\"name\":\"Properties\",\"panels\":[\"object\",\"document\"]}]}"))
        #expect(text.contains("\"dockWidth\":{"))
        #expect(text.contains("\"hiddenDocks\":[\"left\"]"))
        #expect(try JSONDecoder().decode(PanelLayout.self, from: data) == layout)
    }

    @Test func decodesTheDocumentedSample() throws {
        let sample = """
        {
          "version": 1,
          "docks": {
            "right": [ { "name": "Properties", "panels": ["object", "document"], "collapsed": false, "height": 420 } ],
            "left":  [ { "name": "Tools", "panels": ["tools"], "collapsed": false } ]
          },
          "floating": [
            { "name": "Layers", "panels": ["layers"], "frame": [1200, 300, 260, 480], "display": "<uuid>" }
          ],
          "dockWidth": { "right": 280, "left": 44 }
        }
        """
        let layout = try JSONDecoder().decode(PanelLayout.self, from: Data(sample.utf8))
        #expect(layout.docks[.right]?[0].id == "properties")
        #expect(layout.docks[.right]?[0].activePanel == "object")
        #expect(layout.docks[.right]?[0].height == 420)
        #expect(layout.docks[.left]?[0].id == "tools")
        #expect(layout.floating[0].group.id == "layers")
        #expect(layout.floating[0].display == "<uuid>")
        #expect(layout.floating[0].frame == LayoutRect(x: 1200, y: 300, width: 260, height: 480))
        #expect(layout.hiddenDocks.isEmpty)

        let minimal = try JSONDecoder().decode(PanelLayout.self, from: Data("{\"docks\":{\"right\":[{\"panels\":[\"a\"]}]}}".utf8))
        #expect(minimal.version == PanelLayout.currentVersion)
        #expect(minimal.dockWidth == PanelLayout.defaultDockWidth)
        #expect(minimal.docks[.right]?[0].id.count == 36)
        #expect(minimal.docks[.right]?[0].effectiveActivePanel == "a")
        #expect(PanelGroup(panels: [], activePanel: nil).effectiveActivePanel == nil)
        #expect(PanelGroup(panels: ["a"], activePanel: "zzz").effectiveActivePanel == "a")
        #expect(PanelID("a") < PanelID("b"))
        #expect(PanelID("a").description == "a")
    }
}
