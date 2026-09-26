import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender

/// What the print features keep per window (output-area.adoc, "Client"): the output area's dashed
/// rectangle over the canvas in every tool -- drawn after the window's furniture, redrawn when the
/// register changes -- and the local *Show* flag, which is view state on this Mac and never a
/// change.
@MainActor
final class WindowPrint {
    weak var window: DocumentWindowController?
    let document: DocumentHandle
    let defaults: UserDefaults
    private(set) var area: Rect?
    private var observation: DocumentHandle.ObservationToken?
    private var previousDrawer: (@MainActor (CGContext) -> Void)?

    init(window: DocumentWindowController, defaults: UserDefaults) {
        self.window = window
        document = window.documentHandle
        self.defaults = defaults
    }

    static func showKey(_ document: String) -> String { "WTOutputAreaShown.\(document)" }

    /// menu:View[Output Area > Show]: on unless turned off for this document on this Mac.
    var showsArea: Bool {
        get { defaults.object(forKey: Self.showKey(document.id)) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.showKey(document.id))
            window?.canvas.furnitureLayer.setNeedsDisplay()
        }
    }

    func install() {
        guard let canvas = window?.canvas else { return }
        area = OutputArea.read(document.state)
        previousDrawer = canvas.furnitureDrawer
        canvas.furnitureDrawer = { [weak self] ctx in
            self?.previousDrawer?(ctx)
            self?.draw(in: ctx)
        }
        observation = document.observe { [weak self] _ in self?.documentDidChange() }
    }

    func tearDown() {
        if let observation { document.stopObserving(observation) }
        observation = nil
        if let canvas = window?.canvas {
            let previous = previousDrawer
            canvas.furnitureDrawer = previous
        }
    }

    /// A change that moved, resized, defined or removed the area repaints the furniture (and the
    /// tool's handles).
    func documentDidChange() {
        let current = OutputArea.read(document.state)
        guard current != area else { return }
        area = current
        window?.canvas.furnitureLayer.setNeedsDisplay()
        window?.canvas.setNeedsOverlayDisplay()
    }

    func draw(in ctx: CGContext) {
        guard showsArea, let area, let canvas = window?.canvas else { return }
        OutputAreaOverlay.drawBoundary(area, in: ctx, viewport: canvas.viewport)
    }
}

/// The print features (PRINT-002's app glue, PRINT-010, PRINT-011): the Output Area tool, the
/// View menu's *Output Area* items and each window's overlay, menu:File[Page Setup…] and
/// menu:File[Print…] with the *{product}* pane, and the Halftones panel.
@MainActor
final class PrintFeatures {
    enum ID {
        static let showOutputArea: CommandID = "view.outputArea.show"
        static let removeOutputArea: CommandID = "view.outputArea.remove"
    }

    static let noDocument = "No document is open"
    static let noArea = "The document has no output area"

    let defaults: UserDefaults
    var window: @MainActor () -> DocumentWindowController? = { nil }
    /// The blobs a print snapshot reads.
    var blobs = BlobPlacement()
    /// The job's font check for a window's document (PRINT-014); nil checks nothing.
    var fontChecker: @MainActor (DocumentWindowController) -> PrintFontChecker? = { _ in nil }
    /// The window's image store, which placed images print from.
    var imageStore: @MainActor (DocumentWindowController) -> ImageStore? = { _ in nil }
    private(set) var windows: [ObjectIdentifier: (window: DocumentWindowController, print: WindowPrint, closing: NSObjectProtocol?)] = [:]
    /// Runs the print operation (the Print dialog); true when it printed.  Replaceable in tests.
    var runPrint: @MainActor (NSPrintOperation) -> Bool = { $0.run() }
    /// Runs Page Setup on `info`; true on OK.  Replaceable in tests.
    var runPageLayout: @MainActor (NSPrintInfo) -> Bool = { NSPageLayout().runModal(with: $0) == NSApplication.ModalResponse.OK.rawValue }
    /// The last Print dialog shown (tests read it).
    private(set) var session: PrintSession?
    var pane: PrintPaneModel? { session?.pane }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: Windows

    @discardableResult
    func attach(_ window: DocumentWindowController) -> WindowPrint {
        let key = ObjectIdentifier(window)
        if let existing = windows[key] { return existing.print }
        let print = WindowPrint(window: window, defaults: defaults)
        print.install()
        let closing = window.window.map { nswindow in
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nswindow, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated { if let window { self?.detach(window) } }
            }
        }
        windows[key] = (window, print, closing)
        return print
    }

    func detach(_ window: DocumentWindowController) {
        guard let entry = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
        if let closing = entry.closing { NotificationCenter.default.removeObserver(closing) }
        entry.print.tearDown()
    }

    var front: WindowPrint? { window().map(attach) }

    // MARK: Output area

    /// menu:View[Output Area > Show].
    func toggleShowsArea() {
        guard let front else { return }
        front.showsArea.toggle()
    }

    /// menu:View[Output Area > Remove].
    @discardableResult
    func removeArea() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let window = window(), OutputArea.read(window.documentHandle.state) != nil else { return nil }
        return window.objectEditing.perform(SetOutputArea(nil))
    }

    // MARK: Page Setup and Print

    /// The document's archived NSPrintInfo on this Mac, or a copy of the shared one.
    static func printInfo(for document: DocumentHandle) -> NSPrintInfo {
        if let data = DocumentPrintSettings(document.state).printInfo,
           let info = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPrintInfo.self, from: data) {
            return info
        }
        return (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
    }

    static func archive(_ info: NSPrintInfo) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: info, requiringSecureCoding: true)
    }

    /// menu:File[Page Setup…]: the paper and orientation for this document on this Mac, stored as
    /// its local-only print info ("Page Setup", never on the wire).
    @discardableResult
    func pageSetup() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let window = window() else { return nil }
        let info = Self.printInfo(for: window.documentHandle)
        guard runPageLayout(info), let archive = Self.archive(info) else { return nil }
        return window.objectEditing.perform(SetPrintInfo(archive))
    }

    /// menu:File[Print…]: the Print dialog with the *{product}* pane over the print plan's view
    /// (`PrintSession`); after printing, the dialog's printer and paper are kept for the document
    /// on this Mac.  *Selected objects only* offers the selection the window has now.
    @discardableResult
    func print() -> Bool {
        guard let window = window() else { return false }
        let document = window.documentHandle
        let info = Self.printInfo(for: document)
        let selection = Set(window.selection.model.ids.map(\.node))
        let session = PrintSession(document: document, info: info, selection: selection, imageStore: imageStore(window), blobs: blobs,
                                   fonts: fontChecker(window)) { [weak window] command in
            window?.objectEditing.perform(command)
        }
        self.session = session
        let operation = NSPrintOperation(view: session.view, printInfo: info)
        session.info = operation.printInfo
        session.writePreset()
        operation.jobTitle = document.title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.addAccessoryController(session.accessory)
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview, .showsCopies, .showsPageRange])
        session.start()
        defer { session.end() }
        guard runPrint(operation) else { return false }
        if let archive = Self.archive(operation.printInfo) { window.objectEditing.perform(SetPrintInfo(archive)) }
        return true
    }

    // MARK: Commands

    func commands(tools: ToolRegistry) -> [Command] {
        let file = StandardCommands.Menu.file, view = StandardCommands.Menu.view
        let hasWindow: @MainActor @Sendable () -> CommandValidation = { [weak self] in self?.window() == nil ? .disabled(Self.noDocument) : .enabled }
        return [
            Command(id: StandardCommands.ID.pageSetup, title: "Page Setup…", key: KeyEquivalent("p", [.command, .shift]), menu: MenuPath(file, section: 3),
                    keywords: ["paper", "printer", "orientation"], validation: hasWindow, action: .perform { [weak self] in self?.pageSetup() }),
            Command(id: StandardCommands.ID.print, title: "Print…", key: KeyEquivalent("p", .command), menu: MenuPath(file, section: 3),
                    keywords: ["printer", "separations", "pdf"], validation: hasWindow, action: .perform { [weak self] in self?.print() }),
            Command(id: ID.showOutputArea, title: "Show", menu: MenuPath(view, "Output Area", section: StandardCommands.Section.viewRulers),
                    keywords: ["output area", "print area"],
                    validation: { [weak self] in
                        guard let front = self?.front else { return .disabled(Self.noDocument) }
                        return .checked(front.showsArea)
                    },
                    action: .perform { [weak self] in self?.toggleShowsArea() }),
            Command(id: ID.removeOutputArea, title: "Remove", menu: MenuPath(view, "Output Area", section: StandardCommands.Section.viewRulers, subsection: 1),
                    keywords: ["output area", "print area"],
                    validation: { [weak self] in
                        guard let window = self?.window() else { return .disabled(Self.noDocument) }
                        return OutputArea.read(window.documentHandle.state) == nil ? .disabled(Self.noArea) : .enabled
                    },
                    action: .perform { [weak self] in self?.removeArea() }),
        ]
    }

    func install(commands registry: CommandRegistry, tools: ToolRegistry, panels: PanelRegistry, selection: ActiveSelection,
                 window: @escaping @MainActor () -> DocumentWindowController?) {
        self.window = window
        tools.replace(OutputAreaTool.descriptor)
        for command in commands(tools: tools) { registry.replace(command) }
        _ = panels.registerIfAbsent(HalftonesPanel.descriptor(selection: selection))
    }
}

extension AppDelegate {
    /// The Output Area tool and menu items, Page Setup and Print, the Halftones panel, and the
    /// Export sheet's *Output area* choice reading the document's area.
    func installPrinting() {
        let documents = documents!
        printing.blobs = imports.blobs
        printing.imageStore = { [images] window in images.attach(window).store }
        printing.fontChecker = { [fonts, preferences] window in PrintFontChecker.make(fonts: fonts, preferences: preferences, document: window.documentHandle) }
        exports.outputArea = { window in OutputArea.read(window.documentHandle.state) }
        printing.install(commands: commands, tools: tools, panels: panels, selection: activeSelection) { documents.activeWindowController }
    }
}
