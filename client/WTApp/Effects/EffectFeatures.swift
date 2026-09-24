import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// Sheets over the front window (the Create Brush, Blend Steps and Color Control sheets), or a
/// window of their own without one.
@MainActor
final class SheetPresenter {
    /// Presents a sheet window; replaceable in tests.
    var present: @MainActor (NSWindow) -> Void = ColorWorkspace.beginSheet
    private(set) var sheets: [String: NSWindow] = [:]

    init() {}

    func present<Content: View>(_ content: Content, title: String, identifier: String) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        sheets[identifier] = window
        present(window)
    }

    func dismiss(_ identifier: String) {
        guard let sheet = sheets.removeValue(forKey: identifier) else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
    }
}

/// Everything the effects, brush and colour-adjustment UI tasks add to the app, installed by
/// `AppDelegate` in one call (FX-003 and the handles live in the Object panel and the tool
/// manager): the Blend and Extrude tools in place of their stubs (FX-020, FX-027), the blend and
/// extrusion commands of the Modify menu (FX-020, FX-028), menu:Modify[Brush > Create Brush…]
/// (ATTR-009), and the Extensions menu's *Create > Blend* and *Colors* operations with the Color
/// Control sheet (COLOR-017).
@MainActor
final class EffectFeatures {
    enum ID {
        static let createBrush: CommandID = "modify.brush.create"
    }

    static let blendSteps = "blend-steps-sheet"
    static let createBrush = "create-brush-sheet"

    let target: ObjectMenuCommands.Target
    let tools: ExtrudeMenu.Tools
    let sheets: SheetPresenter

    /// No tool manager (a feature set outside a window).
    static func noTools() -> ToolManager? { nil }

    init(target: @escaping ObjectMenuCommands.Target, tools: @escaping ExtrudeMenu.Tools = EffectFeatures.noTools, sheets: SheetPresenter = SheetPresenter()) {
        self.target = target
        self.tools = tools
        self.sheets = sheets
    }

    func install(commands: CommandRegistry, tools registry: ToolRegistry, extensions: ExtensionRegistry) {
        registry.replace(BlendTool.descriptor)
        registry.replace(ExtrudeTool.descriptor)
        for command in self.commands() { commands.replace(command) }
        for descriptor in extensionDescriptors(existing: extensions) { extensions.replace(descriptor) }
    }

    func commands() -> [Command] {
        let target = target
        return BlendMenu.commands(target: target) { [weak self] in self?.showBlendSteps($0) }
            + ExtrudeMenu.commands(target: target, tools: tools)
            + [
                Command(id: ID.createBrush, title: "Create Brush…", menu: MenuPath(ContextMenuCatalog.Menu.modify, "Brush", section: 4),
                        keywords: ["brush", "symbol", "stroke"],
                        validation: BlendMenu.validation(target) { $0.selectedNodes.isEmpty ? ObjectMenuCommands.noSelection : nil },
                        action: .perform { [weak self] in self?.showCreateBrush() }),
            ]
    }

    // MARK: Extensions

    /// The Extensions operations these tasks deliver, replacing their stubs.
    func extensionDescriptors(existing: ExtensionRegistry) -> [ExtensionDescriptor] {
        let target = target
        let selected = BlendMenu.validation(target) { $0.selectedNodes.isEmpty ? ObjectMenuCommands.noSelection : nil }
        let operations: [(String, @MainActor @Sendable () -> CommandValidation, @MainActor (ObjectEditing) -> Void)] = [
            ("colorControl", selected, { [weak self] in self?.showColorControl($0) }),
            ("lightenColors", selected, { $0.perform(AdjustColors($0.selectedNodes, .lighten)) }),
            ("darkenColors", selected, { $0.perform(AdjustColors($0.selectedNodes, .darken)) }),
            ("saturateColors", selected, { $0.perform(AdjustColors($0.selectedNodes, .saturate)) }),
            ("desaturateColors", selected, { $0.perform(AdjustColors($0.selectedNodes, .desaturate)) }),
            ("convertToGrayscale", selected, { $0.perform(ConvertToGrayscale($0.selectedNodes)) }),
            ("randomizeNamedColors", BlendMenu.validation(target) { _ in nil }, { $0.perform(RandomizeSwatches()) }),
        ]
        var result = operations.compactMap { id, validate, run -> ExtensionDescriptor? in
            guard var descriptor = existing.descriptor(for: id) else { return nil }
            descriptor.validate = validate
            descriptor.run = { _ in
                if let editing = target() { run(editing) }
                return nil
            }
            return descriptor
        }
        if let blend = BlendMenu.extensionDescriptor(existing: existing, target: target) { result.append(blend) }
        return result
    }

    // MARK: Sheets

    /// menu:Modify[Blend > Blend Steps…]: the steps of the selected blends.
    func showBlendSteps(_ blends: [OpID]) {
        guard let editing = target() else { return }
        let steps = shared(blends.map { Double(editing.document.state.props($0).blend.steps) })
        sheets.present(BlendStepsSheet(steps: steps ?? 25) { [weak self] value in
            if let value { editing.perform(EditBlend.steps(blends, Int(value.rounded()))) }
            self?.sheets.dismiss(Self.blendSteps)
        }, title: "Blend Steps", identifier: Self.blendSteps)
    }

    /// menu:Modify[Brush > Create Brush…]: the Edit Brush sheet for a brush made from the
    /// selection.
    func showCreateBrush() {
        guard let editing = target(), editing.hasSelection else { return }
        let model = BrushEditorModel(document: editing.document, purpose: .create(editing.selectedNodes))
        sheets.present(BrushEditorSheet(model: model) { [weak self] command in
            if let command { editing.perform(command) }
            self?.sheets.dismiss(Self.createBrush)
        }, title: "Create Brush", identifier: Self.createBrush)
    }

    /// menu:Extensions[Colors > Color Control…] (and the Swatches panel's Options menu).
    func showColorControl(_ editing: ObjectEditing) {
        let model = ColorControlModel(document: editing.document, nodes: editing.selectedNodes)
        sheets.present(ColorControlSheet(model: model) { [weak self] in self?.sheets.dismiss(ColorControlModel.sheet) },
                       title: "Color Control", identifier: ColorControlModel.sheet)
    }

    /// The Swatches panel's Options menu entry.
    func colorControlMenuItem() -> PanelMenuItem {
        let editing = target()
        return PanelMenuItem(title: "Color Control…", isEnabled: editing?.hasSelection ?? false) { [weak self] in
            if let editing { self?.showColorControl(editing) }
        }
    }
}

/// menu:Modify[Blend > Blend Steps…]: one field, 1 ... 1000.
struct BlendStepsSheet: View {
    let steps: Double
    let finish: @MainActor (Double?) -> Void
    @State private var value: Double?

    static func cancelling(_ finish: @escaping @MainActor (Double?) -> Void) -> () -> Void { { finish(nil) } }

    /// btn:[OK]: the typed steps (the current ones when nothing was typed), 1 ... 1000.
    static func confirming(_ value: Double?, steps: Double, finish: @escaping @MainActor (Double?) -> Void) -> () -> Void {
        { finish(min(max(value ?? steps, 1), 1000)) }
    }

    static func text(_ value: Binding<Double?>, steps: Double) -> Binding<String> {
        Binding(get: { String(Int(value.wrappedValue ?? steps)) }, set: { value.wrappedValue = Double($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Blend Steps").font(.headline)
            TextField("Steps", text: Self.text($value, steps: steps)).accessibilityIdentifier("blend-steps.field")
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancelling(finish)).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.confirming(value, steps: steps, finish: finish)).keyboardShortcut(.defaultAction).accessibilityIdentifier("blend-steps.ok")
            }
        }
        .padding(20)
        .frame(width: 260)
    }
}
