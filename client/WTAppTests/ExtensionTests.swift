import AppKit
import SwiftUI
import Testing
@testable import WireTuner

/// BASIC-031 and BASIC-032: the extension registry, the Extensions menu, Repeat and Manage
/// Extensions.
@Suite @MainActor struct ExtensionTests {
    /// extensions.adoc's menu table, submenu by submenu.
    static let pageTable: [(String, [String])] = [
        ("Animate", ["Release to Layers"]),
        ("Chart", ["Pictograph…", "Remove Pictograph"]),
        ("Cleanup", ["Correct Direction", "Remove Overlap", "Reverse Direction", "Simplify…"]),
        ("Colors", [
            "Color Control…", "Convert to Grayscale", "Darken Colors", "Desaturate Colors", "Import RGB Color Table…", "Lighten Colors",
            "Name All Colors", "Randomize Named Colors", "Saturate Colors", "Sort Color List by Name",
        ]),
        ("Create", ["Blend", "Emboss…", "Fractalize", "Trap…"]),
        ("Delete", ["Empty Text Blocks", "Unused Named Colors"]),
        ("Distort", ["Add Points", "Bend…", "Fisheye Lens…", "Roughen…", "Smudge…", "3D Rotation…"]),
        ("Path Operations", ["Union", "Divide", "Intersect", "Punch", "Crop", "Transparency…", "Expand Stroke…", "Inset Path…"]),
        ("Other", ["File Info…", "Manage Extensions…"]),
    ]

    static let toolsToolbar = [
        "Mirror", "Roughen", "Bend", "Fisheye Lens", "Smudge", "Shadow", "3D Rotation", "Graphic Hose", "Chart", "Spiral", "Arc",
        "Eyedropper", "Extrude", "Blend", "Perspective", "Connector", "Link", "Output Area", "Eraser",
    ]

    static let operationsToolbar = [
        "Union", "Divide", "Intersect", "Punch", "Crop", "Transparency", "Expand Stroke", "Inset Path", "Add Points", "Correct Direction",
        "Reverse Direction", "Remove Overlap", "Simplify", "Blend", "Emboss", "Fractalize", "Trap", "Release to Layers",
    ]

    private func menu(_ registry: ExtensionRegistry, commands: CommandRegistry = CommandRegistry(), manage: @escaping @MainActor @Sendable () -> Void = {}) -> [MenuNode] {
        ExtensionCommands.sync(into: commands, registry: registry, showManage: manage)
        let tree = MenuTreeBuilder.build(registry: commands, shortcuts: ShortcutSet.builtInDefault(commands: commands.commands))
        return tree.items(inMenu: "Extensions") ?? []
    }

    private func submenus(_ nodes: [MenuNode]) -> [(String, [String])] {
        nodes.compactMap { node in
            guard case let .submenu(title, items) = node else { return nil }
            return (title, items.compactMap(\.title))
        }
    }

    @Test func theMenuMatchesThePageTable() {
        let nodes = menu(ExtensionRegistry())
        guard case let .item(repeatItem) = nodes[0] else { Issue.record("Repeat first"); return }
        #expect(repeatItem.commandID == ExtensionCommands.ID.repeatLast)
        #expect(repeatItem.key == KeyEquivalent("=", [.command, .shift]))
        #expect(nodes[1] == .separator)
        let actual = submenus(nodes)
        #expect(actual.map(\.0) == Self.pageTable.map(\.0))
        #expect(actual.map(\.1) == Self.pageTable.map(\.1))
    }

    @Test func theToolbarsDefaultSetsFollowThePage() {
        let registry = ExtensionRegistry()
        let tools = registry.defaultItems(for: .tools).compactMap { registry.descriptor(forCommand: $0)?.shortTitle }
        #expect(tools == Self.toolsToolbar)
        let operations = registry.defaultItems(for: .operations).compactMap { registry.descriptor(forCommand: $0)?.shortTitle }
        #expect(operations == Self.operationsToolbar)
        // The toolbar flags agree with the toolbar order.
        let flagged = Set(ExtensionCatalog.operations.filter { $0.toolbars.contains(.operations) }.map(\.id))
        #expect(flagged == Set(ExtensionCatalog.operationsToolbarOrder))
        for descriptor in ExtensionCatalog.tools {
            guard case let .tool(id) = descriptor.kind else { Issue.record("tool kind"); continue }
            #expect(ToolCatalog.all.contains { $0.id == id }, "\(id) is a registered tool")
            #expect(descriptor.commandID == ToolRegistry.commandID(for: id))
        }
        #expect(Set(ExtensionCatalog.all.map(\.id)).count == ExtensionCatalog.all.count)
        #expect(ExtensionCatalog.all.allSatisfy { !$0.helpSlug.isEmpty && !$0.symbolName.isEmpty })
    }

    @Test func stubOperationsAreDisabledComingSoon() {
        let registry = ExtensionRegistry()
        let commands = CommandRegistry()
        _ = menu(registry, commands: commands)
        let union = ExtensionRegistry.commandID(for: "union")
        let validation = commands.validate(union)!
        #expect(!validation.isEnabled)
        #expect(validation.reason == "Union is coming soon")
        #expect(!commands.perform(union))
        #expect(!registry.perform("union"))
        #expect(!registry.perform("nope"))
        #expect(registry.validation(ofExtension: "nope").reason == "Unknown extension")
        #expect(registry.descriptor(for: "simplify")?.shortTitle == "Simplify")
        #expect(registry.descriptor(for: "union")?.shortTitle == "Union")
    }

    @Test func repeatRerunsWithCapturedParametersAndIsDisabledAfterATool() {
        let registry = ExtensionRegistry()
        let commands = CommandRegistry()
        let probe = OperationProbe()
        var sample = registry.descriptor(for: "fractalize")!
        sample.validate = { probe.selectionHasPaths ? .enabled : .disabled("Select a path") }
        sample.run = { parameters in
            probe.runs.append(parameters)
            return parameters ?? ["segments": "12"]
        }
        var changes = 0
        registry.onChange = { changes += 1 }
        registry.replace(sample)
        registry.replace(ExtensionDescriptor(id: "unknown", title: "U", category: "X", symbolName: "x", helpSlug: "x"))
        #expect(changes == 1)
        _ = menu(registry, commands: commands)

        #expect(commands.validate(ExtensionCommands.ID.repeatLast) == CommandValidation(isEnabled: false, reason: "No extension to repeat", title: "Repeat Extension"))
        #expect(!commands.perform(ExtensionCommands.ID.repeatLast))
        #expect(commands.perform(ExtensionRegistry.commandID(for: "fractalize")))
        #expect(probe.runs.count == 1 && probe.runs[0] == nil)
        #expect(registry.repeatState == ExtensionRepeatState(extensionID: "fractalize", parameters: ["segments": "12"]))
        let validation = commands.validate(ExtensionCommands.ID.repeatLast)!
        #expect(validation.isEnabled && validation.title == "Repeat Fractalize")

        // On a new selection, with the same settings.
        #expect(commands.perform(ExtensionCommands.ID.repeatLast))
        #expect(probe.runs.last == ["segments": "12"])
        probe.selectionHasPaths = false
        #expect(commands.validate(ExtensionCommands.ID.repeatLast)?.isEnabled == false)
        #expect(!registry.performRepeat())
        probe.selectionHasPaths = true

        // An operation that captured nothing repeats with empty settings, never asking again.
        var plain = registry.descriptor(for: "addPoints")!
        plain.run = { parameters in
            probe.runs.append(parameters)
            return nil
        }
        registry.replace(plain)
        #expect(registry.perform("addPoints"))
        #expect(registry.performRepeat())
        #expect(probe.runs.last == [:])

        registry.noteToolUsed()
        #expect(registry.repeatState == nil)
        #expect(commands.validate(ExtensionCommands.ID.repeatLast)?.isEnabled == false)
        #expect(!registry.performRepeat())
    }

    @Test func turningOffHidesMenuItemsAndPersists() {
        let suite = TestDefaults()
        let registry = ExtensionRegistry(defaults: suite.defaults)
        let commands = CommandRegistry()
        var nodes = menu(registry, commands: commands)
        #expect(submenus(nodes).contains { $0.0 == "Path Operations" })

        var changes = 0
        registry.onChange = { changes += 1 }
        registry.setEnabled(false, category: "Path Operations")
        #expect(changes == 1)
        registry.setEnabled(false, category: "Path Operations")
        #expect(changes == 1, "no change, no notification")
        #expect(registry.categoryState("Path Operations") == false)
        #expect(registry.hiddenCommands.contains(ExtensionRegistry.commandID(for: "union")))
        nodes = menu(registry, commands: commands)
        #expect(!submenus(nodes).contains { $0.0 == "Path Operations" })
        #expect(commands.contains(ExtensionRegistry.commandID(for: "union")), "still registered")
        #expect(commands.validate(ExtensionRegistry.commandID(for: "union"))?.reason == "Turned off in Manage Extensions")

        // Chart disabled: the tool stays registered and usable in documents.
        registry.setEnabled(false, "tool.chart")
        #expect(registry.categoryState("Chart") == nil, "partly on")
        #expect(registry.hiddenCommands.contains(ToolRegistry.commandID(for: "chart")))

        let reloaded = ExtensionRegistry(defaults: suite.defaults)
        #expect(!reloaded.isEnabled("union") && !reloaded.isEnabled("tool.chart") && reloaded.isEnabled("simplify"))
        #expect(suite.defaults.stringArray(forKey: "wt.extensions.disabled")?.contains("union") == true)

        registry.setEnabled(true, category: "Path Operations")
        registry.setEnabled(true, "tool.chart")
        #expect(registry.categoryState("Chart") == true)
        nodes = menu(registry, commands: commands)
        #expect(submenus(nodes).map(\.1) == Self.pageTable.map(\.1), "back in place, in order")
        #expect(registry.categories.map(\.title) == ["Animate", "Chart", "Cleanup", "Colors", "Create", "Delete", "Distort", "Path Operations", "Other", "Tools"])
    }

    @Test func theManageSheetTogglesItemsAndCategories() {
        let registry = ExtensionRegistry()
        let controller = ManageExtensionsController(registry: registry)
        let window = controller.show(attachedTo: nil)
        #expect(window.identifier?.rawValue == "extensions.manage")
        #expect(controller.window === window)

        var refreshed = 0
        let view = ManageExtensionsView(registry: registry, revision: 0, onChange: { refreshed += 1 }, done: {})
        view.binding(extension: "union").wrappedValue = false
        #expect(!registry.isEnabled("union") && refreshed == 1)
        #expect(view.binding(extension: "union").wrappedValue == false)
        #expect(view.binding(category: "Path Operations").wrappedValue == false)
        view.binding(category: "Path Operations").wrappedValue = true
        #expect(registry.isEnabled("union") && refreshed == 2)
        #expect(view.binding(category: "Path Operations").wrappedValue == true)

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 480)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)

        controller.refresh()
        controller.makeView().onChange()
        controller.makeView().done()
        #expect(controller.window == nil)
        controller.close()

        // As a sheet on a document window.
        let parent = TestWindow.make(NSRect(x: 0, y: 0, width: 400, height: 400))
        let sheet = controller.show(attachedTo: parent)
        #expect(sheet.identifier?.rawValue == "extensions.manage")
        controller.close()
        #expect(controller.window == nil)
    }
}

/// A sample operation's state, shared with its closures.
@MainActor
final class OperationProbe {
    var runs: [ExtensionParameters?] = []
    var selectionHasPaths = true
}
