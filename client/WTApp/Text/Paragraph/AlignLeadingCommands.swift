import AppKit
import Observation
import SwiftUI
import WTModel
import WTProto

/// Leading as the Text menu, the Text toolbar and the Object panel read it (type-specifications.adoc,
/// "Leading"): the mode and value of each run's `leading` mark, an unset mark reading as *Auto*
/// (120%).
extension ObjectPanelModel {
    /// *Auto* leading: 120% of the size (the default when a run has no leading mark).
    static let autoLeading = Wiretuner_Doc_V1_Leading.with { $0.mode = .percent; $0.value = 120 }
    /// *Solid* leading: the size plus nothing.
    static let solidLeading = Wiretuner_Doc_V1_Leading.with { $0.mode = .extra; $0.value = 0 }

    /// The leading of one run: its `leading` mark, else *Auto*.  An unspecified mode reads as Extra.
    static func leading(_ values: [Wiretuner_Doc_V1_TextMarkValue]) -> Wiretuner_Doc_V1_Leading {
        for value in values {
            if case .leading(var leading)? = value.value {
                if leading.mode == .unspecified { leading.mode = .extra }
                return leading
            }
        }
        return autoLeading
    }

    /// The leadings the targeted text holds (the Text tool's selection, else every selected block).
    var leadings: Set<Wiretuner_Doc_V1_Leading> { Set(fontRuns.map(Self.leading)) }

    /// Writes `leading` on the targeted text: one mark, one change "Leading".
    @discardableResult
    func setLeading(_ leading: Wiretuner_Doc_V1_Leading) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard text != nil, AlignLeadingCommands.isValid(leading) else { return nil }
        return formatText(.with { $0.leading = leading })
    }
}

/// menu:Text[Align] and menu:Text[Leading], the same items of the text context menus, and the
/// Text toolbar's alignment buttons and *Leading* item (type-tools.adoc, "The Text menu"; the
/// alignment and leading part of TYPE-017).  Alignment is a paragraph setting (`SetParagraph`
/// field 1, one change "Alignment"); leading a character mark (one change "Leading").  While the
/// Text tool edits, both apply to its selection -- the caret's paragraph, or the pending format at
/// an insertion point.
@MainActor
enum AlignLeadingCommands {
    typealias Window = @MainActor () -> DocumentWindowController?

    enum ID {
        static func align(_ name: String) -> CommandID { ContextMenuCatalog.ID.align(name) }
        static func leading(_ name: String) -> CommandID { ContextMenuCatalog.ID.leading(name) }
        /// The Text toolbar's *Leading* item: opens the *Leading > Other…* sheet.
        static let toolbarLeading: CommandID = "text.leading"
    }

    static let alignMenu = "Align"
    static let leadingMenu = "Leading"
    static let contexts: Set<MenuContext> = [.text, .textEditing]

    /// The four alignments with their command names and default keys.  Only Center gets the
    /// documented kbd:[Cmd+Shift+C]: kbd:[Cmd+Shift+L] is Unlock, kbd:[Cmd+Shift+R] Export and
    /// kbd:[Cmd+Shift+J] Split in the default set.
    static let alignments: [(name: String, title: String, value: Wiretuner_Doc_V1_Alignment, key: KeyEquivalent?)] = [
        ("left", "Left", .left, nil),
        ("center", "Center", .center, KeyEquivalent("c", [.command, .shift])),
        ("right", "Right", .right, nil),
        ("justified", "Justified", .justified, nil),
    ]

    /// Leading values a sheet or the Object panel accepts: Extra from -1,000 to 1,000 points,
    /// Fixed from 0.1 to 10,000 points, Percentage from 1 to 1,000.
    static func isValid(_ leading: Wiretuner_Doc_V1_Leading) -> Bool {
        guard leading.value.isFinite else { return false }
        switch leading.mode {
        case .extra, .unspecified: return (-1000...1000).contains(leading.value)
        case .fixed: return (0.1...10_000).contains(leading.value)
        case .percent: return (1...1000).contains(leading.value)
        case .UNRECOGNIZED: return false
        }
    }

    static func model(_ window: DocumentWindowController?) -> ObjectPanelModel? {
        FontCommands.model(window)
    }

    // MARK: Commands

    static func commands(window: @escaping Window) -> [Command] {
        let text = ContextMenuCatalog.Menu.text
        var result = alignments.map { item in
            Command(id: ID.align(item.name), title: item.title, key: item.key, menu: MenuPath(text, alignMenu, section: 1), contexts: contexts,
                    keywords: ["align", "alignment", "paragraph", item.name],
                    validation: {
                        guard let model = model(window()), let section = model.text else { return .disabled(TextFeatures.noText) }
                        return .checked(section.alignment == item.value)
                    },
                    action: .perform { model(window())?.setAlignment(item.value) })
        }
        let presets: [(name: String, title: String, leading: Wiretuner_Doc_V1_Leading)] = [
            ("solid", "Solid", ObjectPanelModel.solidLeading), ("auto", "Auto", ObjectPanelModel.autoLeading),
        ]
        result += presets.map { preset in
            Command(id: ID.leading(preset.name), title: preset.title, menu: MenuPath(text, leadingMenu, section: 1), contexts: contexts,
                    keywords: ["leading", "line spacing", preset.name],
                    validation: {
                        guard let model = model(window()) else { return .disabled(TextFeatures.noText) }
                        return .checked(model.leadings == [preset.leading])
                    },
                    action: .perform { model(window())?.setLeading(preset.leading) })
        }
        result.append(Command(id: ID.leading("other"), title: "Other…", menu: MenuPath(text, leadingMenu, section: 1), contexts: contexts,
                              keywords: ["leading", "line spacing"], validation: FontCommands.hasText(window),
                              action: .perform { if let front = window() { showLeading(on: front) } }))
        result.append(Command(id: ID.toolbarLeading, title: "Leading", keywords: ["toolbar", "text", "leading"], validation: FontCommands.hasText(window),
                              action: .perform { if let front = window() { showLeading(on: front) } }))
        return result
    }

    /// The *Leading > Other…* sheet over `window`: btn:[OK] applies and closes.
    @discardableResult
    static func showLeading(on window: DocumentWindowController) -> NSWindow? {
        let leadings = model(window)?.leadings ?? []
        let sheet = LeadingSheetModel(leading: leadings.count == 1 ? leadings.first : nil)
        return window.presentSheet(LeadingSheetModel.sheet) { close in
            LeadingSheet(model: sheet, commit: { [weak window] leading in
                model(window)?.setLeading(leading)
                close()
            }, cancel: close)
        }
    }
}

/// The *Leading > Other…* sheet's state: the mode and the typed value.
@MainActor
@Observable
final class LeadingSheetModel {
    static let sheet = "text-leading-other"
    static let modes: [(mode: Wiretuner_Doc_V1_LeadingMode, title: String)] = [(.extra, "Extra (+)"), (.fixed, "Fixed (=)"), (.percent, "Percentage (%)")]

    var mode: Wiretuner_Doc_V1_LeadingMode
    var text: String

    /// `leading` is the text's shared leading; nil (mixed) starts at Auto with an empty field.
    init(leading: Wiretuner_Doc_V1_Leading?) {
        mode = leading?.mode ?? .percent
        text = leading.map { Self.format($0.value) } ?? ""
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// The leading typed, nil while the value is not a number in the mode's range.
    var leading: Wiretuner_Doc_V1_Leading? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "pt", with: "")
        guard let value = Double(trimmed.trimmingCharacters(in: .whitespaces)) else { return nil }
        let leading = Wiretuner_Doc_V1_Leading.with { $0.mode = mode; $0.value = value }
        return AlignLeadingCommands.isValid(leading) ? leading : nil
    }
}

struct LeadingSheet: View {
    @Bindable var model: LeadingSheetModel
    let commit: @MainActor (Wiretuner_Doc_V1_Leading) -> Void
    let cancel: @MainActor () -> Void

    static func committing(_ model: LeadingSheetModel, _ commit: @escaping @MainActor (Wiretuner_Doc_V1_Leading) -> Void) -> () -> Void {
        { if let leading = model.leading { commit(leading) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Leading").font(.headline)
            Picker("Mode", selection: $model.mode) {
                ForEach(LeadingSheetModel.modes, id: \.mode) { Text($0.title).tag($0.mode) }
            }
            .accessibilityIdentifier("leading-other.mode")
            TextField("Value", text: $model.text, prompt: Text(TextSectionView.mixed)).frame(width: 90).accessibilityIdentifier("leading-other.value")
            if model.leading == nil, !model.text.isEmpty {
                Text("Enter a value in the mode's range.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.committing(model, commit)).keyboardShortcut(.defaultAction)
                    .disabled(model.leading == nil).accessibilityIdentifier("leading-other.ok")
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

/// The Object panel's *Leading* row under the Text section (type-specifications.adoc, "Leading"):
/// the mode pop-up and the value, both showing *Mixed* when the text differs.
struct LeadingSectionView: View {
    let model: ObjectPanelModel

    static let mixedTag = Wiretuner_Doc_V1_LeadingMode.UNRECOGNIZED(-1)

    /// The shared leading, nil when the text differs.
    static func shared(_ model: ObjectPanelModel) -> Wiretuner_Doc_V1_Leading? {
        let leadings = model.leadings
        return leadings.count == 1 ? leadings.first : nil
    }

    /// The mode pop-up: choosing a mode keeps the value when it fits the mode, else the mode's
    /// usual value (Extra 0, Fixed the size × 1.2, Percentage 120).
    static func mode(_ model: ObjectPanelModel) -> Binding<Wiretuner_Doc_V1_LeadingMode> {
        Binding(get: { shared(model)?.mode ?? mixedTag }, set: { mode in
            guard mode != mixedTag else { return }
            var leading = Wiretuner_Doc_V1_Leading.with { $0.mode = mode; $0.value = shared(model)?.value ?? 0 }
            if !AlignLeadingCommands.isValid(leading) || shared(model)?.mode != mode {
                leading.value = switch mode {
                case .fixed: (model.text?.size ?? ObjectPanelModel.defaultSize) * 1.2
                case .percent: 120
                default: 0
                }
            }
            model.setLeading(leading)
        })
    }

    static func value(_ model: ObjectPanelModel) -> (Double) -> Void {
        { value in
            let mode = shared(model)?.mode ?? .extra
            model.setLeading(.with { $0.mode = mode; $0.value = value })
        }
    }

    var body: some View {
        let shared = Self.shared(model)
        Form {
            Picker("Leading", selection: Self.mode(model)) {
                if shared == nil { Text(TextSectionView.mixed).tag(Self.mixedTag) }
                ForEach(LeadingSheetModel.modes, id: \.mode) { Text($0.title).tag($0.mode) }
            }
            .accessibilityIdentifier("object.text.leadingMode")
            CommitField(title: "Leading value", value: shared?.value, identifier: "object.text.leading", commit: Self.value(model))
        }
        .padding(.horizontal)
    }
}

extension AlignLeadingCommands {
    /// The Object panel's Leading row, for text blocks and the instances whose text the Text tool
    /// edits.
    static func register(into registry: InspectorRegistry) {
        registry.register(InspectorSection(id: "textLeading", order: 60, kinds: [.text, .instance]) { model in
            model.text.map { _ in AnyView(LeadingSectionView(model: model)) }
        })
    }
}
