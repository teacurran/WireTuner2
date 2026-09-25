import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The Styles panel body (styles.adoc, "The Styles panel"): the graphic styles as a compact or
/// large list (preview, name, count, plus sign) or as previews only (name on hover), then the text
/// styles.  A style's preview drags onto the canvas (apply) or onto another style (redefine);
/// objects and styles dropped on the empty area make a style.
struct StylesPanelBody: View {
    @Bindable var model: StylesPanelModel

    static func clicking(_ style: OpID, _ model: StylesPanelModel) -> () -> Void {
        { model.click(style) }
    }

    static func clickingText(_ row: StylesPanelModel.TextRow, _ model: StylesPanelModel) -> () -> Void {
        { model.clickText(row) }
    }

    static func renaming(_ style: OpID, _ model: StylesPanelModel) -> () -> Void {
        { model.beginRename(style) }
    }

    static func dragging(_ style: OpID, _ model: StylesPanelModel) -> () -> NSItemProvider {
        { model.dragPayload(style)?.itemProvider ?? NSItemProvider() }
    }

    static func dropping(on target: OpID?, _ model: StylesPanelModel, pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> ([NSItemProvider]) -> Bool {
        { _ in model.drop(from: pasteboard, on: target) }
    }

    /// What the panel takes: styles and objects.
    static let dropTypes = [StyleDrag.utType, StyleDrag.objectsUTType]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.document == nil {
                Text(StylesPanelModel.noDocument).font(.callout).foregroundStyle(.secondary).padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.viewMode == .previewsOnly { grid } else { list }
                        if !model.textRows.isEmpty { textStyles }
                        SwiftUI.Color.clear.frame(maxWidth: .infinity, minHeight: 32)
                            .contentShape(Rectangle())
                            .onDrop(of: Self.dropTypes, isTargeted: nil, perform: Self.dropping(on: nil, model))
                            .accessibilityIdentifier("styles.empty")
                    }
                }
                .onDrop(of: Self.dropTypes, isTargeted: nil, perform: Self.dropping(on: nil, model))
                .onDeleteCommand(perform: ColorAction.run(model.remove))
                .onExitCommand(perform: model.cancelRename)
                .accessibilityIdentifier("styles.list")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelContextMenu(.style)
    }

    private var list: some View {
        ForEach(model.rows) { row in
            StyleRowView(row: row, model: model)
                .onDrop(of: Self.dropTypes, isTargeted: nil, perform: Self.dropping(on: row.id, model))
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: StylePreview.large.width + 4), spacing: 4)], spacing: 4) {
            ForEach(model.rows) { row in
                Button(action: Self.clicking(row.id, model)) {
                    StylePreviewImage(image: model.preview(row.id), size: model.viewMode.previewSize)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(SwiftUI.Color.accentColor, lineWidth: row.isHighlighted ? 2 : 0))
                        .overlay(alignment: .topTrailing) { Text(row.isModified ? "+" : "").font(.caption.bold()) }
                }
                .buttonStyle(.plain)
                .help(row.name)
                .onDrag(Self.dragging(row.id, model))
                .onDrop(of: Self.dropTypes, isTargeted: nil, perform: Self.dropping(on: row.id, model))
                .accessibilityIdentifier("styles.preview.\(row.name)")
            }
        }
        .accessibilityIdentifier("styles.grid")
    }

    private var textStyles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Text styles").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 6)
            ForEach(model.textRows) { row in
                Button(action: Self.clickingText(row, model)) {
                    HStack {
                        Text("Aa").font(.system(size: model.viewMode == .compact ? 11 : 18)).frame(width: model.viewMode.previewSize.width)
                        Text(row.name).italic(row.kind == .character)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("styles.text.\(row.name)")
            }
        }
    }
}

/// One graphic style in a list view: preview (drag it), name (a field while renaming), the plus
/// sign and the object count.
struct StyleRowView: View {
    let row: StylesPanelModel.Row
    @Bindable var model: StylesPanelModel

    var body: some View {
        HStack(spacing: 6) {
            StylePreviewImage(image: model.preview(row.id), size: model.viewMode.previewSize)
                .onDrag(StylesPanelBody.dragging(row.id, model))
            if model.renaming == row.id {
                TextField("Name", text: $model.renameText)
                    .onSubmit(ColorAction.run(model.commitRename))
                    .accessibilityIdentifier("styles.rename")
            } else {
                Button(action: StylesPanelBody.clicking(row.id, model)) {
                    Text(row.name).fontWeight(row.isNormal ? .semibold : .regular)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded(StylesPanelBody.renaming(row.id, model)))
            }
            if row.isModified {
                Text("+").font(.callout.bold()).help("Differs from the style").accessibilityIdentifier("styles.plus")
            }
            Spacer()
            Text("\(row.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(2)
        .background(row.isHighlighted ? SwiftUI.Color.accentColor.opacity(0.2) : SwiftUI.Color.clear)
        .accessibilityIdentifier("styles.row.\(row.name)")
        .accessibilityValue(row.isModified ? "modified" : "")
    }
}

/// A preview image, or an empty frame.
struct StylePreviewImage: View {
    let image: CGImage?
    let size: Size

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
            } else {
                RoundedRectangle(cornerRadius: 3).stroke(SwiftUI.Color.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The Redefine sheet (styles.adoc, "Modifying and redefining styles"): confirms which style takes
/// the dropped object's, the other style's or the default attributes' look.
struct RedefineStyleSheet: View {
    @Bindable var model: StylesPanelModel

    static func choosing(_ model: StylesPanelModel) -> Binding<OpID> {
        Binding(get: { model.redefinition?.style ?? OpID(counter: 0, replica: 0) }, set: { model.redefinition?.style = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Redefine Style").font(.headline)
            if let redefinition = model.redefinition {
                Picker("Style", selection: Self.choosing(model)) {
                    ForEach(model.rows) { row in Text(row.name).tag(row.id) }
                }
                .accessibilityIdentifier("styles.redefine.style")
                Text("The style takes the look of \(model.sourceDescription(redefinition.source)); every object using it changes, except where it overrides.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancelRedefine).keyboardShortcut(.cancelAction)
                Button("Redefine", action: ColorAction.run(model.confirmRedefine)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("styles.redefine.ok")
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// The Style Behavior sheet (styles.adoc, "Style behavior", "Basing one style on another"): the
/// categories the style governs (at least one stays checked) and its *Parent*, leaving out the
/// styles that would form a loop.  Normal takes no parent.
struct StyleBehaviorSheet: View {
    @Bindable var model: StylesPanelModel

    static let titles: [(StyleCategory, String)] = [(.fills, "Fills"), (.strokes, "Strokes"), (.effects, "Effects"), (.halftone, "Halftone")]

    static func checking(_ category: StyleCategory, _ model: StylesPanelModel) -> Binding<Bool> {
        Binding(get: { model.behavior?.governs.contains(category) ?? false }, set: { _ in model.toggle(category) })
    }

    static func parent(_ model: StylesPanelModel) -> Binding<OpID?> {
        Binding(get: { model.behavior?.parent }, set: { model.setParent($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Style Behavior").font(.headline)
            if let behavior = model.behavior {
                Text(model.name(of: behavior.style)).font(.callout)
                ForEach(Self.titles, id: \.0) { category, title in
                    Toggle(title, isOn: Self.checking(category, model)).accessibilityIdentifier("styles.behavior.\(title)")
                }
                Picker("Parent", selection: Self.parent(model)) {
                    Text("None").tag(OpID?.none)
                    ForEach(model.parentCandidates, id: \.self) { style in Text(model.name(of: style)).tag(OpID?.some(style)) }
                }
                .disabled(behavior.isNormal)
                .accessibilityIdentifier("styles.behavior.parent")
            }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancelBehavior).keyboardShortcut(.cancelAction)
                Button("OK", action: ColorAction.run(model.confirmBehavior)).keyboardShortcut(.defaultAction).accessibilityIdentifier("styles.behavior.ok")
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

/// The Remove Unused sheet: the styles about to go.
struct RemoveUnusedStylesSheet: View {
    @Bindable var model: StylesPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove Unused Styles").font(.headline)
            if model.unused.isEmpty {
                Text("Every style is in use.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.unused, id: \.self) { style in Text(model.name(of: style)) }
            }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancelRemoveUnused).keyboardShortcut(.cancelAction)
                Button("Remove", action: ColorAction.run(model.confirmRemoveUnused)).keyboardShortcut(.defaultAction)
                    .disabled(model.unused.isEmpty).accessibilityIdentifier("styles.unused.ok")
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
