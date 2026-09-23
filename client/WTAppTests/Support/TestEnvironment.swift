import AppKit
import Foundation
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// A throwaway `UserDefaults` suite, removed by `remove()`.
@MainActor
final class TestDefaults {
    let name = "WireTunerTests.\(UUID().uuidString)"
    nonisolated(unsafe) let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    func remove() {
        defaults.removePersistentDomain(forName: name)
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}

/// Registries, preferences and a temporary window-state store for one test.
@MainActor
final class TestEnvironment {
    let commands = CommandRegistry()
    let panels = PanelRegistry()
    let layout: PanelLayoutController
    let tools = ToolRegistry()
    let suite = TestDefaults()
    let preferences: PreferenceStore
    let windowStates: WindowStateStore
    private(set) var performed: [CommandID] = []
    var shortcuts = ShortcutSet.builtInDefault(commands: [])

    init() {
        PlaceholderPanels.register(into: panels)
        layout = PanelLayoutController(registry: panels)
        layout.load()
        tools.registerBuiltIn()
        preferences = PreferenceStore(defaults: suite.defaults)
        windowStates = WindowStateStore(url: TestEnvironment.temporaryDirectory().appending(path: WindowStateStore.fileName))
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "WireTunerTests-\(UUID().uuidString)")
    }

    var document: DocumentEnvironment {
        var environment = DocumentEnvironment(
            commands: commands, panels: panels, layout: layout, tools: tools, preferences: preferences,
            windowStates: windowStates,
            shortcuts: { [unowned self] in self.shortcuts },
            perform: { [unowned self] id in
                self.performed.append(id)
                return self.commands.perform(id)
            }
        )
        environment.makeTiles = { CanvasView.makeFallbackTiles() }
        return environment
    }
}

/// A canvas host that records what tools ask of it.
@MainActor
final class RecordingHost: CanvasHost {
    var viewport: Viewport
    private(set) var overlayRequests = 0
    private(set) var cursorChanges = 0
    private(set) var messages: [String] = []

    init(viewport: Viewport = Viewport(size: Size(width: 400, height: 300))) {
        self.viewport = viewport
    }

    private(set) var namedViewRequests: [Viewport] = []

    func setViewport(_ viewport: Viewport) { self.viewport = viewport }
    func requestNamedView(_ target: Viewport) { namedViewRequests.append(target) }
    func setNeedsOverlayDisplay() { overlayRequests += 1 }
    func toolCursorDidChange() { cursorChanges += 1 }
    func showStatusMessage(_ message: String) { messages.append(message) }
}

/// A command sink that records commands and performs nothing.
@MainActor
final class RecordingSink: CommandSink {
    private(set) var commands: [any WTModel.Command] = []

    @discardableResult
    func perform(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        commands.append(command)
        return Task { nil }
    }
}

/// A tool that records every call.
@MainActor
final class RecordingTool: Tool {
    static let id: ToolID = "recording"
    let toolID: ToolID
    private(set) var calls: [String] = []
    var consumesKeys = false

    init(id: ToolID) {
        toolID = id
    }

    var cursor: NSCursor { .pointingHand }
    func activate(in context: ToolContext) { calls.append("activate") }
    func deactivate() { calls.append("deactivate") }
    func mouseDown(_ e: CanvasEvent) { calls.append("down") }
    func mouseDragged(_ e: CanvasEvent) { calls.append("drag") }
    func mouseUp(_ e: CanvasEvent) { calls.append("up") }
    func flagsChanged(_ e: CanvasEvent) { calls.append("flags:\(e.modifiers.rawValue)") }
    func keyDown(_ e: NSEvent) -> Bool {
        calls.append("key:\(e.charactersIgnoringModifiers ?? "")")
        return consumesKeys
    }
    func drawOverlay(in ctx: CGContext, viewport: Viewport) { calls.append("overlay") }
    func cancel() { calls.append("cancel") }
}

enum TestEvents {
    static func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], up: Bool = false, repeat isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: keyCode
        )!
    }

    static var space: NSEvent { key(" ", keyCode: 49) }
    static var spaceUp: NSEvent { key(" ", keyCode: 49, up: true) }
    static var escape: NSEvent { key("\u{1B}", keyCode: 53) }

    static func point(_ x: Double, _ y: Double, _ modifiers: KeyModifiers = []) -> CanvasEvent {
        CanvasEvent(pasteboardPoint: Point(x: x, y: y), viewPoint: Point(x: x, y: y), modifiers: modifiers)
    }
}
