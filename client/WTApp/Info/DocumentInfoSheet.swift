import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// menu:File[Document Info…] (file-info.adoc, "Adding document information"; IO-011): the four
/// sections of IPTC fields over the document's `DocumentInfo`, read from the document on every
/// render so a collaborator's edit shows at once, each field committed on Return or when it loses
/// focus as one change ("Change Document Info"), keywords added and removed as tokens.
@MainActor
@Observable
final class DocumentInfoModel {
    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Void
    /// Why the last commit was refused.
    private(set) var message: String?
    @ObservationIgnored var onClose: @MainActor () -> Void = {}

    init(document: DocumentHandle, perform: @escaping @MainActor (any WTModel.Command) -> Void) {
        self.document = document
        self.perform = perform
    }

    var values: DocumentInfoValues {
        _ = document.model?.revision
        return DocumentInfoValues(document.state)
    }

    /// The field's text; a list field as its names joined by commas.
    func text(_ field: DocumentInfoField) -> String {
        let values = values
        switch field {
        case .creators: return values.info.creators.joined(separator: ", ")
        case .supplementalCategories: return values.info.supplementalCategories.joined(separator: ", ")
        default: return values[field]
        }
    }

    /// Commits `text` to `field` unless it is unchanged; a list field splits at commas.
    func commit(_ field: DocumentInfoField, _ text: String) {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines) != self.text(field) else { return }
        let value: SetDocumentInfo.Value = field.isText ? .text(text) : .list(text.split(separator: ",").map(String.init))
        apply(SetDocumentInfo(field, value))
    }

    var copyrightStatus: Wiretuner_Doc_V1_CopyrightStatus { values.info.copyrightStatus }

    func setCopyrightStatus(_ status: Wiretuner_Doc_V1_CopyrightStatus) {
        guard status != copyrightStatus else { return }
        apply(SetDocumentInfo(.copyrightStatus, .copyrightStatus(status)))
    }

    var keywords: [String] { values.keywords }

    /// Return in the keyword field: each comma-separated word becomes a token.
    func addKeywords(_ text: String) {
        let words = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return }
        apply(SetDocumentKeywords(adding: words))
    }

    func removeKeyword(_ keyword: String) {
        apply(SetDocumentKeywords(removing: [keyword]))
    }

    /// The first time the sheet opens on a document with no creator, the creator is the user.
    func prefillCreator(_ name: String) {
        guard values.info.creators.isEmpty, !name.isEmpty else { return }
        apply(SetDocumentInfo(.creators, .list([name])))
    }

    /// "12/256" for a field with a limit.
    func counter(_ field: DocumentInfoField, draft: String) -> String { "\(draft.count)/\(field.limit)" }

    private func apply(_ command: any WTModel.Command) {
        do {
            _ = try command.validated(in: document.state)
            message = nil
            perform(command)
        } catch {
            message = Self.describe(error)
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error as? DocumentInfoError {
        case .tooLong(let field)?: "\(field.title) is too long."
        case .tooMany(let field)?: "\(field.title) has too many entries."
        case .invalidURL?: "The web statement must be a URL."
        case .keywords?: "Keywords are at most 64 characters, and 500 in all."
        default: "The change could not be made."
        }
    }

    static let sections: [(title: String, fields: [DocumentInfoField])] = [
        ("Description", [.title, .headline, .description, .category, .supplementalCategories]),
        ("Creator", [.creators, .creatorJobTitle, .credit, .source]),
        ("Rights", [.copyrightNotice, .rightsUsageTerms, .webStatement]),
        ("Origin", [.dateCreated, .city, .state, .country, .instructions, .language]),
    ]
}

extension WTModel.Command {
    /// Runs the command on a scratch builder over `state`, so a refusal shows before the change is
    /// performed (the document's `perform` reports errors only to its log).
    func validated(in state: EngineState) throws -> Bool {
        var builder = ChangeBuilder(replica: 0, startCounter: 1)
        try execute(&builder, state: state)
        return true
    }
}

/// One text field that keeps what is typed while it has focus and commits on Return or on losing
/// focus; a remote change shows while it does not have focus (the APP-007 rule).
struct InfoTextField: View {
    let field: DocumentInfoField
    let model: DocumentInfoModel
    @State private var draft: String?
    @FocusState private var focused: Bool

    static func binding(_ draft: Binding<String?>, value: String) -> Binding<String> {
        Binding(get: { draft.wrappedValue ?? value }, set: { draft.wrappedValue = $0 })
    }

    static func commit(_ model: DocumentInfoModel, _ field: DocumentInfoField, draft: String?) {
        if let draft { model.commit(field, draft) }
    }

    /// Return: the draft is committed and the field shows the document again.
    static func submit(_ model: DocumentInfoModel, _ field: DocumentInfoField, draft: Binding<String?>) -> () -> Void {
        {
            commit(model, field, draft: draft.wrappedValue)
            draft.wrappedValue = nil
        }
    }

    /// Losing focus commits like Return.
    static func focusChanged(_ model: DocumentInfoModel, _ field: DocumentInfoField, draft: Binding<String?>, focused: Bool) {
        if !focused { submit(model, field, draft: draft)() }
    }

    var body: some View {
        let value = model.text(field)
        HStack {
            TextField(field.title, text: Self.binding($draft, value: value), axis: [.description, .instructions, .rightsUsageTerms].contains(field) ? .vertical : .horizontal)
                .focused($focused)
                .onSubmit(Self.submit(model, field, draft: $draft))
                .onChange(of: focused) { _, now in Self.focusChanged(model, field, draft: $draft, focused: now) }
                .accessibilityIdentifier("documentInfo.\(field)")
            if field.isText {
                Text(model.counter(field, draft: draft ?? value)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

struct DocumentInfoSheet: View {
    let model: DocumentInfoModel
    @State private var keyword = ""

    static func status(_ model: DocumentInfoModel) -> Binding<Int> {
        Binding(get: { model.copyrightStatus.rawValue }, set: { model.setCopyrightStatus(Wiretuner_Doc_V1_CopyrightStatus(rawValue: $0)!) })
    }

    /// Return in the keyword field.
    static func addKeyword(_ model: DocumentInfoModel, _ keyword: Binding<String>) -> () -> Void {
        {
            model.addKeywords(keyword.wrappedValue)
            keyword.wrappedValue = ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                ForEach(DocumentInfoModel.sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.fields, id: \.rawValue) { field in InfoTextField(field: field, model: model) }
                        if section.title == "Description" {
                            KeywordTokenField(keywords: model.keywords, add: model.addKeywords, remove: model.removeKeyword)
                                .accessibilityIdentifier("documentInfo.keywords")
                        }
                        if section.title == "Rights" {
                            Picker("Copyright status", selection: Self.status(model)) {
                                Text("Unknown").tag(0)
                                Text("Copyrighted").tag(1)
                                Text("Public domain").tag(2)
                            }
                            .accessibilityIdentifier("documentInfo.copyrightStatus")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red).accessibilityIdentifier("documentInfo.message")
            }
            HStack {
                Spacer()
                Button("Done", action: model.onClose).keyboardShortcut(.defaultAction).accessibilityIdentifier("documentInfo.done")
            }
        }
        .padding(16)
        .frame(width: 520, height: 640)
    }
}

/// The keyword tokens, each with a remove button.
struct FlowTokens: View {
    let tokens: [String]
    let remove: @MainActor (String) -> Void

    static func remove(_ token: String, _ remove: @escaping @MainActor (String) -> Void) -> () -> Void { { remove(token) } }

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(tokens, id: \.self) { token in
                    HStack(spacing: 2) {
                        Text(token)
                        Button(action: Self.remove(token, remove)) { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("documentInfo.remove.\(token)")
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            }
        }
        .accessibilityIdentifier("documentInfo.keywords")
    }
}

/// The Document Info command and its sheet.
@MainActor
final class DocumentInfoFeatures {
    static let id: CommandID = "file.documentInfo"
    static let sheetID = "document-info-sheet"

    var window: @MainActor () -> DocumentWindowController? = { nil }
    /// The signed-in person's name (the creator prefill).
    var userName: @MainActor () -> String = { "" }
    var presentSheet: @MainActor (NSWindow, NSWindow?) -> Void = { sheet, parent in
        if let parent { parent.beginSheet(sheet) } else { sheet.makeKeyAndOrderFront(nil) }
    }
    private(set) var sheet: NSWindow?

    init() {}

    @discardableResult
    func present() -> DocumentInfoModel? {
        guard let window = window() else { return nil }
        let model = DocumentInfoModel(document: window.documentHandle) { [weak window] command in window?.objectEditing.perform(command) }
        model.prefillCreator(userName())
        model.onClose = { [weak self] in self?.dismiss() }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: DocumentInfoSheet(model: model)))
        sheet.identifier = NSUserInterfaceItemIdentifier(Self.sheetID)
        sheet.title = "Document Info"
        sheet.isReleasedWhenClosed = false
        sheet.animationBehavior = .none
        self.sheet = sheet
        presentSheet(sheet, window.window)
        return model
    }

    func dismiss() {
        guard let sheet else { return }
        self.sheet = nil
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
    }

    func command() -> Command {
        Command(id: Self.id, title: "Document Info…", key: KeyEquivalent("i", [.command, .option]), menu: MenuPath(StandardCommands.Menu.file, section: 2),
                keywords: ["metadata", "iptc", "copyright", "keywords", "creator"],
                validation: { [weak self] in self?.window() == nil ? .disabled("No document is open") : .enabled },
                action: .perform { [weak self] in self?.present() })
    }

    func install(into registry: CommandRegistry, window: @escaping @MainActor () -> DocumentWindowController?) {
        self.window = window
        registry.replace(command())
    }
}

extension AppDelegate {
    /// menu:File[Document Info…] (IO-011).
    func installDocumentInfo() {
        let documents = documents!
        let account = account
        documentInfo.userName = { account.profile?.displayName ?? "" }
        documentInfo.install(into: commands) { documents.activeWindowController }
    }
}
