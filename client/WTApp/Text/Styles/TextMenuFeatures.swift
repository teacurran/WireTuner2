import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// menu:Text[Convert Case] (editing-text.adoc, "Changing case"; the menu and sheet of TYPE-015): the
/// five conversions of the targeted text, each one change, and *Settings…*, the sheet with the
/// *Small caps size* and the exceptions list, whose btn:[OK] is one `SetTextCaseSettings`.
@MainActor
@Observable
final class TextCaseSettingsModel {
    /// One exception row as edited.
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var original: OpID?
        var word: String
        var conversions: Set<CaseConversion>
    }

    var smallCapsPercent: Double
    var rows: [Row]

    static let sheet = "text-case-settings"

    init(_ settings: TextCaseSettings) {
        smallCapsPercent = settings.smallCapsPercent
        rows = settings.exceptions.map { Row(original: $0.id, word: $0.word, conversions: $0.conversions) }
    }

    func addRow() {
        rows.append(Row(original: nil, word: "", conversions: [.title]))
    }

    func remove(_ id: UUID) {
        rows.removeAll { $0.id == id }
    }

    func toggle(_ conversion: CaseConversion, in id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if rows[index].conversions.contains(conversion) { rows[index].conversions.remove(conversion) } else { rows[index].conversions.insert(conversion) }
    }

    /// What btn:[OK] writes: the size (10...100) and the rows with a word.
    var settings: TextCaseSettings {
        TextCaseSettings(smallCapsPercent: min(max(smallCapsPercent, 10), 100),
                         exceptions: rows.filter { !$0.word.trimmingCharacters(in: .whitespaces).isEmpty }
                             .map { CaseExceptionInfo(id: $0.original, word: $0.word.trimmingCharacters(in: .whitespaces), conversions: $0.conversions) })
    }
}

/// The Convert Case Settings sheet.
struct TextCaseSettingsSheet: View {
    @Bindable var model: TextCaseSettingsModel
    let commit: @MainActor (TextCaseSettings) -> Void
    let cancel: @MainActor () -> Void

    static func wordBinding(_ id: UUID, _ model: TextCaseSettingsModel) -> Binding<String> {
        Binding(get: { model.rows.first { $0.id == id }?.word ?? "" }, set: { word in
            if let index = model.rows.firstIndex(where: { $0.id == id }) { model.rows[index].word = word }
        })
    }

    static func removing(_ id: UUID, _ model: TextCaseSettingsModel) -> () -> Void {
        { model.remove(id) }
    }

    static func committing(_ model: TextCaseSettingsModel, _ commit: @escaping @MainActor (TextCaseSettings) -> Void) -> () -> Void {
        { commit(model.settings) }
    }

    static func conversionBinding(_ conversion: CaseConversion, _ id: UUID, _ model: TextCaseSettingsModel) -> Binding<Bool> {
        Binding(get: { model.rows.first { $0.id == id }?.conversions.contains(conversion) ?? false }, set: { _ in model.toggle(conversion, in: id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Convert Case Settings").font(.headline)
            HStack {
                Text("Small caps size")
                TextField("Size", value: $model.smallCapsPercent, format: .number).frame(width: 60).accessibilityIdentifier("case-settings.size")
                Text("%")
            }
            Text("Exceptions").font(.subheadline)
            ForEach(model.rows) { row in
                HStack {
                    TextField("Word", text: Self.wordBinding(row.id, model)).frame(width: 120)
                    ForEach(CaseConversion.allCases, id: \.self) { conversion in
                        Toggle(conversion.title, isOn: Self.conversionBinding(conversion, row.id, model)).toggleStyle(.checkbox)
                    }
                    Button(action: Self.removing(row.id, model)) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button("Add Exception", action: model.addRow).accessibilityIdentifier("case-settings.add")
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.committing(model, commit)).keyboardShortcut(.defaultAction).accessibilityIdentifier("case-settings.ok")
            }
        }
        .padding(20)
        .frame(minWidth: 620)
    }
}

/// The Text menu's items for the text-style tasks: Convert Case (five conversions and *Settings…*,
/// TYPE-015) and *Convert to Paths* (TYPE-044, with the Missing Fonts note when a substitute drew
/// some text), and the Object panel's style and colour sections (TYPE-034, TYPE-029).
@MainActor
enum TextStyleFeatures {
    typealias Window = TextFeatures.Window

    enum ID {
        static let caseSettings: CommandID = "text.case.settings"
        static let sentence: CommandID = ContextMenuCatalog.ID.convertCase("sentence")
        static let smallCaps: CommandID = ContextMenuCatalog.ID.convertCase("smallCaps")
    }

    /// The menu ids of the conversions (the catalog's upper, lower and title stubs among them).
    static let conversions: [(id: CommandID, conversion: CaseConversion, title: String)] = [
        (ContextMenuCatalog.ID.convertCase("upper"), .uppercase, "UPPERCASE"), (ContextMenuCatalog.ID.convertCase("lower"), .lowercase, "lowercase"),
        (ContextMenuCatalog.ID.convertCase("title"), .title, "Title Case"), (ID.sentence, .sentence, "Sentence case"), (ID.smallCaps, .smallCaps, "Small Caps"),
    ]

    static let linkedText = "Linked text cannot be converted to paths"

    /// Converts the targeted text of `model`'s selection; nil without text (a caret converts nothing).
    @discardableResult
    static func convert(_ conversion: CaseConversion, model: ObjectPanelModel?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let model else { return nil }
        let targets = model.textTargets.filter { !$0.range.isEmpty }
        guard !targets.isEmpty else { return nil }
        return model.perform(CommandBatch(conversion.title, targets.map { ConvertCase(node: $0.node, from: $0.from, to: $0.to, conversion: conversion) }))
    }

    /// *Settings…* on `window`.
    @discardableResult
    static func showCaseSettings(on window: DocumentWindowController) -> NSWindow? {
        let document = window.documentHandle
        let model = TextCaseSettingsModel(TextCaseSettings(document.state))
        return window.presentSheet(TextCaseSettingsModel.sheet) { close in
            TextCaseSettingsSheet(model: model, commit: { settings in
                document.perform(SetTextCaseSettings(settings))
                close()
            }, cancel: close)
        }
    }

    /// menu:Text[Convert to Paths]: every selected text block converted, one change; the fonts a
    /// substitute drew are named; a linked block refuses.
    @discardableResult
    static func convertToPaths(_ window: DocumentWindowController?, alert: @MainActor (String, String) -> Void) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let window else { return nil }
        let document = window.documentHandle
        let state = document.state
        let texts = window.selection.selection.ids.map(\.opID).filter { state.nodeKind($0) == .text }
        guard !texts.isEmpty else { return nil }
        var conversions: [TextConversion] = []
        for node in texts {
            do {
                conversions.append(try TextToPaths.conversion(node, in: state, engine: document.textEngine))
            } catch {
                alert(linkedText, "Unlink the text first, or convert the blocks of the chain together.")
                return nil
            }
        }
        let missing = Set(conversions.flatMap(\.substitutedFonts)).sorted()
        if !missing.isEmpty { alert("Some fonts were missing", "Converted with a substitute for \(missing.joined(separator: ", ")).") }
        return window.objectEditing.perform(ConvertTextToPaths(conversions))
    }

    /// The app's alert over the front window.
    static func showAlert(_ title: String, _ detail: String) {
        ModalUI.alert(title, detail, on: NSApp.mainWindow)
    }

    static func commands(window: @escaping Window, alert: @escaping @MainActor (String, String) -> Void = TextStyleFeatures.showAlert) -> [Command] {
        let text = ContextMenuCatalog.Menu.text
        let hasText: @MainActor @Sendable () -> CommandValidation = { TextFeatures.model(window())?.text == nil ? .disabled(TextFeatures.noText) : .enabled }
        var result = conversions.map { item in
            Command(id: item.id, title: item.title, menu: MenuPath(text, "Convert Case", section: 1), keywords: ["case", "capitals"], validation: hasText,
                    action: .perform { convert(item.conversion, model: TextFeatures.model(window())) })
        }
        result.append(Command(id: ID.caseSettings, title: "Settings…", menu: MenuPath(text, "Convert Case", section: 1, subsection: 1),
                              keywords: ["case", "small caps", "exceptions"],
                              validation: { window() == nil ? .disabled(BlendMenu.noDocument) : .enabled },
                              action: .perform { if let front = window() { showCaseSettings(on: front) } }))
        result.append(Command(id: ContextMenuCatalog.ID.convertToPaths, title: "Convert to Paths", menu: MenuPath(text, section: 2),
                              keywords: ["outlines", "glyphs", "paths"],
                              validation: { () -> CommandValidation in
                                  guard let front = window() else { return .disabled(TextFeatures.noText) }
                                  let state = front.documentHandle.state
                                  return front.selection.selection.ids.contains { state.nodeKind($0.opID) == .text } ? .enabled : .disabled(TextFeatures.noText)
                              },
                              action: .perform { convertToPaths(window(), alert: alert) }))
        return result
    }

    /// The sections, registered with the Object panel's registry.
    static func register(into registry: InspectorRegistry) {
        registry.register(InspectorSection(id: "textStyle", order: 60, kinds: [.text]) { model in
            model.textStyle.map { AnyView(TextStyleSectionView(section: $0, model: model)) }
        })
        registry.register(InspectorSection(id: "textColor", order: 64, kinds: [.text]) { model in
            model.textColor.map { AnyView(TextColorSectionView(section: $0, model: model)) }
        })
    }

    static func install(into registry: CommandRegistry, inspector: InspectorRegistry, window: @escaping Window) {
        for command in commands(window: window) { registry.replace(command) }
        register(into: inspector)
    }
}

extension AppDelegate {
    func installTextStyles() {
        let documents = documents!
        TextStyleFeatures.install(into: commands, inspector: .standard) { documents.activeWindowController }
    }
}
