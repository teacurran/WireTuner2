import AppKit
import Foundation
import Testing
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// Windows a test makes itself.  An `NSWindow` is released when closed by default, a release
/// ARC does not know about: closing one a test (or its sheet) still holds over-releases it, and
/// an in-flight sheet or ordering animation (`_NSWindowTransformAnimation`) then touches the
/// freed window when the run loop next drains -- crashing the test host in a later test.  These
/// are kept alive by their owner, not by `close()`, and do not animate.
@MainActor
enum TestWindow {
    static func make(_ rect: NSRect = NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: NSWindow.StyleMask = [.titled], defer deferred: Bool = false) -> NSWindow {
        prepare(NSWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: deferred))
    }

    static func make(contentViewController: NSViewController) -> NSWindow {
        prepare(NSWindow(contentViewController: contentViewController))
    }

    @discardableResult
    static func prepare(_ window: NSWindow) -> NSWindow {
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }
}

/// Document windows a test leaves alive.  Windows made over a `TestEnvironment` are reported by
/// it (`WT-WINDOW-LEAK`, 3 s after the environment went); every other one -- the app's own, made
/// through `AppDelegate` or a `DocumentController` -- is reported as `WT-WINDOW-LEAK-APP` when its
/// controller is still alive a minute after it was made (no test holds a window that long on
/// purpose).
@MainActor
enum WindowLeakLog {
    private struct Entry {
        weak var controller: DocumentWindowController?
        let test: String
        let made: Date
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]
    private static var claimed: Set<ObjectIdentifier> = []
    private static var started = false
    static let age: TimeInterval = 60

    static func start() {
        guard !started else { return }
        started = true
        DocumentEnvironment.everyWindowDidLoad = { controller in
            let key = ObjectIdentifier(controller)
            guard !claimed.contains(key) else {
                claimed.remove(key)
                return
            }
            let test = Test.current.map { "\($0.name) \($0.sourceLocation.fileName):\($0.sourceLocation.line)" } ?? "?"
            entries[key] = Entry(controller: controller, test: test, made: Date())
        }
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(10))
                sweep(now: Date())
            }
        }
    }

    /// A window a `TestEnvironment` reports itself.
    static func claim(_ controller: DocumentWindowController) {
        claimed.insert(ObjectIdentifier(controller))
    }

    private static func sweep(now: Date) {
        for (key, entry) in entries {
            guard let controller = entry.controller else {
                entries[key] = nil
                continue
            }
            guard now.timeIntervalSince(entry.made) > age else { continue }
            entries[key] = nil
            print("WT-WINDOW-LEAK-APP window=\(controller.window?.isVisible == true ? "open" : "closed") \(entry.test)")
        }
    }
}

/// A throwaway `UserDefaults` suite, removed by `remove()`.
@MainActor
final class TestDefaults {
    let name = "WireTunerTests.\(UUID().uuidString)"
    nonisolated(unsafe) let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
        WindowLeakLog.start()
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
    /// The windows of the document windows made over this environment, closed when it goes if a
    /// test left them open: an open window outlives its controller (the application holds it) with
    /// its whole view tree and tile cache, and over a full suite those added up to gigabytes.
    nonisolated(unsafe) private var openWindows: [ObjectIdentifier: (window: WeakWindow, closing: NSObjectProtocol)] = [:]

    /// Every window made here with the test that made it, to report the ones still alive a moment
    /// after the environment went (`WT-WINDOW-LEAK <test>` in the log).
    nonisolated(unsafe) private var madeWindows: [(window: WeakWindow, test: String)] = []

    private struct WeakWindow {
        weak var window: NSWindow?
        weak var canvas: CanvasView?
        weak var controller: DocumentWindowController?
    }

    private func track(_ controller: DocumentWindowController) {
        guard let window = controller.window else { return }
        let key = ObjectIdentifier(window)
        let closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget(key) }
        }
        WindowLeakLog.claim(controller)
        let weak = WeakWindow(window: window, canvas: controller.canvas, controller: controller)
        openWindows[key] = (weak, closing)
        let test = Test.current.map { "\($0.name) \($0.sourceLocation.fileName):\($0.sourceLocation.line)" } ?? "?"
        madeWindows.append((weak, test))
    }

    private func forget(_ key: ObjectIdentifier) {
        if let entry = openWindows.removeValue(forKey: key) { NotificationCenter.default.removeObserver(entry.closing) }
    }

    init() {
        WindowLeakLog.start()
        PlaceholderPanels.register(into: panels)
        layout = PanelLayoutController(registry: panels)
        layout.load()
        tools.registerBuiltIn()
        preferences = PreferenceStore(defaults: suite.defaults)
        windowStates = WindowStateStore(url: TestEnvironment.temporaryDirectory().appending(path: WindowStateStore.fileName))
    }

    deinit {
        let entries = Array(openWindows.values)
        for entry in entries { NotificationCenter.default.removeObserver(entry.closing) }
        let windows = entries.compactMap(\.window.window)
        let canvases = entries.compactMap(\.window.canvas)
        let made = madeWindows
        let registry = commands
        let panelRegistry = panels
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            // The controller may be gone (it is the window's delegate, weakly): drop the canvas's
            // pixels directly, then close.
            for canvas in canvases { canvas.discardContents() }
            for window in windows { window.close() }
            // The windows made here hold the command and panel registries (their environment's);
            // what a test registered there often captures a window or a feature attached to one,
            // which would keep that window alive through the registry.
            registry.remove(Set(registry.ids))
            registry.onChange = nil
            panelRegistry.removeAll()
            guard !made.isEmpty else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                for entry in made where entry.window.window != nil || entry.window.canvas != nil {
                    print("WT-WINDOW-LEAK window=\(entry.window.window != nil) canvas=\(entry.window.canvas != nil) controller=\(entry.window.controller != nil) title=\(entry.window.window?.title ?? "") \(entry.test)")
                }
            }
        }
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
        environment.windowDidLoad = { [weak self] controller in self?.track(controller) }
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
