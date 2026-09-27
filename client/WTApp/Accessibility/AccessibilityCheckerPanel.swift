import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// menu:File[Check Accessibility…] (names-notes.adoc, "Checking a document for accessibility";
/// IO-033): the report of `WTModel.AccessibilityCheck` over the window's scene -- missing
/// descriptions, low contrast, each page's reading order and the document language.  A row's
/// object is selected by clicking it; alt text typed in a row, or *Decorative* ticked there, is one
/// change `Describe "name"` that undoes on its own.  While the panel is open every page's reading
/// order is drawn as numbered badges on the canvas; btn:[Arrange…] opens the Reading Order panel.
/// The check writes nothing.  Deviation: a floating panel rather than a sheet, like Reading Order,
/// so the canvas stays live for the badges and the selection.
@MainActor
@Observable
final class AccessibilityCheckerModel {
    /// Weak: the panel (kept by `AccessibilityCheckerFeatures`) can outlive its window; with the
    /// window gone the report stays as it was and the fixes do nothing.
    @ObservationIgnored private(set) weak var window: DocumentWindowController?
    private(set) var report = AccessibilityReport()
    /// Alt text being typed per row.
    var drafts: [OpID: String] = [:]

    init(window: DocumentWindowController) {
        self.window = window
        refresh()
    }

    var document: DocumentHandle? { window?.documentHandle }

    /// Runs the check again (after a fix, or when asked).
    func refresh() {
        guard let document else { return }
        report = AccessibilityCheck.run(document.state, displayList: document.displayList) { document.textLayout(for: $0) }
    }

    func name(_ node: OpID) -> String { document?.state.displayName(of: node) ?? "" }

    /// A row clicked: its object is the selection.
    func select(_ node: OpID) {
        window?.selection.model.set(Selection([SelectionID(node)]))
    }

    private func fix(_ node: OpID, _ fix: DescribeObject.Fix) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        guard let window else { return Task { nil } }
        let task = window.objectEditing.perform(DescribeObject(node, fix, name: name(node)))
        return Task { @MainActor in
            let change = await task.value
            self.drafts[node] = nil
            self.refresh()
            return change
        }
    }

    /// The row's typed alt text, written.
    @discardableResult
    func describe(_ node: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let text = drafts[node]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return fix(node, .alt(String(text.prefix(DescriptionFields.maxAlt))))
    }

    @discardableResult
    func markDecorative(_ node: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        fix(node, .decorative(true))
    }

    /// btn:[Arrange…]: the Reading Order panel for the current page.
    @discardableResult
    func arrange() -> ReadingOrderModel? { window.map { ReadingOrderFeatures.show(on: $0) } }

    /// The badges of every page's reading order: number and the object's top-left (pasteboard).
    var badges: [(number: Int, at: Point)] {
        guard let state = document?.state else { return [] }
        return report.readingOrder.flatMap { page in
            page.order.enumerated().compactMap { index, node in
                Objects.bounds(of: node, in: state).map { (index + 1, Point(x: $0.minX, y: $0.minY)) }
            }
        }
    }

    static func ratio(_ value: Double) -> String { String(format: "%.1f:1", value) }
}

struct AccessibilityCheckerView: View {
    @Bindable var model: AccessibilityCheckerModel
    let done: () -> Void

    static func draft(_ model: AccessibilityCheckerModel, _ node: OpID) -> Binding<String> {
        Binding(get: { model.drafts[node] ?? "" }, set: { model.drafts[node] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accessibility").font(.headline)
            List {
                Section("Missing descriptions") {
                    if model.report.missing.isEmpty { Text("Every image and drawing is described.").foregroundStyle(.secondary) }
                    ForEach(model.report.missing) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                model.select(row.node)
                            } label: {
                                Text("\(row.name) — \(row.reason.rawValue)" + (row.page.map { ", page \($0)" } ?? ""))
                            }
                            .buttonStyle(.plain)
                            HStack {
                                TextField("Alt text", text: Self.draft(model, row.node)).onSubmit { model.describe(row.node) }
                                    .accessibilityIdentifier("accessibility.alt.\(row.node)")
                                Button("Decorative") { model.markDecorative(row.node) }.accessibilityIdentifier("accessibility.decorative.\(row.node)")
                            }
                        }
                    }
                }
                Section("Low contrast") {
                    if model.report.lowContrast.isEmpty { Text("All text meets the contrast ratio.").foregroundStyle(.secondary) }
                    ForEach(model.report.lowContrast) { row in
                        Button {
                            model.select(row.node)
                        } label: {
                            Text("\(model.name(row.node)), line \(row.line + 1): \(AccessibilityCheckerModel.ratio(row.ratio)) (needs \(AccessibilityCheckerModel.ratio(row.required)))")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Reading order") {
                    ForEach(model.report.readingOrder) { page in
                        HStack {
                            Text("\(page.name): \(page.order.count) objects")
                            Spacer()
                            Button("Arrange…") { model.arrange() }.accessibilityIdentifier("accessibility.arrange.\(page.number)")
                        }
                    }
                }
                if model.report.missingLanguage {
                    Section("Document language") {
                        Text("Document Info has no language; tagged PDF needs one.").accessibilityIdentifier("accessibility.language")
                    }
                }
            }
            .frame(minHeight: 280)
            HStack {
                Button("Check Again") { model.refresh() }.accessibilityIdentifier("accessibility.refresh")
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction).accessibilityIdentifier("accessibility.done")
            }
        }
        .padding()
        .frame(width: 400)
    }
}

/// The panel per window, the canvas badges and the command.
@MainActor
enum AccessibilityCheckerFeatures {
    static let id: CommandID = "file.checkAccessibility"
    /// Tests keep panels from ordering front.
    static var showsPanel = true

    private struct Entry {
        weak var window: DocumentWindowController?
        let panel: NSPanel
        let model: AccessibilityCheckerModel
    }

    private struct Drawing {
        weak var window: DocumentWindowController?
    }

    private static var open: [ObjectIdentifier: Entry] = [:]
    /// The windows whose canvas draws the badges while a panel is open (weakly: an identifier a
    /// freed window left may come back for another window).
    private static var drawing: [ObjectIdentifier: Drawing] = [:]

    /// Panels left by windows that closed without btn:[Done] go.
    private static func prune() {
        for (key, entry) in open where entry.window == nil {
            entry.panel.orderOut(nil)
            open[key] = nil
        }
        drawing = drawing.filter { $0.value.window != nil }
    }

    static func model(of window: DocumentWindowController) -> AccessibilityCheckerModel? {
        guard let entry = open[ObjectIdentifier(window)], entry.window === window else { return nil }
        return entry.model
    }

    @discardableResult
    static func show(on window: DocumentWindowController) -> AccessibilityCheckerModel {
        if let existing = model(of: window) {
            existing.refresh()
            if showsPanel { open[ObjectIdentifier(window)]?.panel.orderFront(nil) }
            return existing
        }
        prune()
        let model = AccessibilityCheckerModel(window: window)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 480), styleMask: [.titled, .closable, .utilityWindow, .resizable],
                            backing: .buffered, defer: true)
        panel.identifier = NSUserInterfaceItemIdentifier("accessibility-check")
        panel.title = "Check Accessibility"
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: AccessibilityCheckerView(model: model) { [weak window] in
            if let window { close(window) }
        })
        open[ObjectIdentifier(window)] = Entry(window: window, panel: panel, model: model)
        if drawing[ObjectIdentifier(window)]?.window !== window {
            drawing[ObjectIdentifier(window)] = Drawing(window: window)
            window.canvas.overlayExtras.append { [weak window] ctx, viewport in
                guard let window, let checker = Self.model(of: window) else { return }
                for badge in checker.badges { ReadingOrderHandles.drawBadge(badge.number, at: viewport.toView(badge.at), in: ctx) }
            }
        }
        window.canvas.setNeedsOverlayDisplay()
        if showsPanel { panel.makeKeyAndOrderFront(nil) }
        return model
    }

    static func close(_ window: DocumentWindowController) {
        guard model(of: window) != nil, let entry = open.removeValue(forKey: ObjectIdentifier(window)) else { return }
        entry.panel.orderOut(nil)
        window.canvas.setNeedsOverlayDisplay()
    }

    static func command(window: @escaping @MainActor () -> DocumentWindowController?) -> Command {
        Command(id: id, title: "Check Accessibility…", menu: MenuPath(StandardCommands.Menu.file, section: 3),
                keywords: ["accessibility", "alt text", "contrast", "screen reader", "wcag"],
                validation: { window() == nil ? .disabled("Open a document") : .enabled },
                action: .perform { if let front = window() { show(on: front) } })
    }
}
