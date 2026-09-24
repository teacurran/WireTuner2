import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WTModel

/// The progress sheet of `wt.ui.progress` (title, fraction, text and btn:[Cancel]).
@MainActor
@Observable
final class ScriptProgressModel {
    var title = ""
    var fraction = 0.0
    var text = ""
    @ObservationIgnored var cancel: @MainActor () -> Void = {}
}

struct ScriptProgressSheet: View {
    let model: ScriptProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.title.isEmpty ? "Running script" : model.title).font(.headline)
            ProgressView(value: min(max(model.fraction, 0), 1)) { Text(model.text).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("script.progress.cancel")
            }
        }
        .padding()
        .frame(width: 320)
    }
}

/// The main actor's side of `wt.ui` on a window: alerts, the prompt and choice alerts, the open
/// and save panels (a script gets contents or a writer token, never a path), the progress sheet
/// and `wt.records.merge`.  The panels and alerts are replaceable in tests.
@MainActor
final class ScriptUI {
    weak var window: DocumentWindowController?
    let data: DataFeatures?
    /// btn:[Cancel] on the progress sheet.
    var onCancel: @MainActor () -> Void = {}
    var runAlert: @MainActor (NSAlert, NSWindow?) async -> NSApplication.ModalResponse = { await DataConsent.present($0, on: $1) }
    var chooseOpen: @MainActor (NSOpenPanel, NSWindow?) async -> URL? = { await ModalUI.urls($0, on: $1).first }
    var chooseSave: @MainActor (NSSavePanel, NSWindow?) async -> URL? = { await ModalUI.url($0, on: $1) }
    /// Configures a script's merge before it runs (tests replace its panels and printing).
    var prepareMerge: @MainActor (MergeSheetModel) -> Void = { _ in }
    let progress = ScriptProgressModel()
    private(set) var progressSheet: NSWindow?
    private var writers: [String: URL] = [:]

    init(window: DocumentWindowController?, data: DataFeatures?) {
        self.window = window
        self.data = data
        progress.cancel = { [weak self] in self?.onCancel() }
    }

    private static func text(_ arguments: [Any], _ index: Int) -> String {
        index < arguments.count ? (arguments[index] as? String ?? "\(arguments[index])") : ""
    }

    /// The answer to `call` (`NSNull` for JavaScript's null), or nil when there is no such call.
    func handle(_ call: String, _ arguments: [Any]) async -> Any? {
        switch call {
        case "alert":
            _ = await alert(Self.text(arguments, 0), buttons: ["OK"])
            return NSNull()
        case "confirm":
            return await alert(Self.text(arguments, 0), buttons: ["OK", "Cancel"]).response == .alertFirstButtonReturn
        case "prompt":
            let field = NSTextField(string: Self.text(arguments, 1))
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            let (response, _) = await alert(Self.text(arguments, 0), buttons: ["OK", "Cancel"], accessory: field)
            return response == .alertFirstButtonReturn ? field.stringValue : NSNull()
        case "choose":
            let choices = (arguments.count > 1 ? arguments[1] as? [Any] : nil)?.map { "\($0)" } ?? []
            let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
            popUp.addItems(withTitles: choices)
            let (response, _) = await alert(Self.text(arguments, 0), buttons: ["OK", "Cancel"], accessory: popUp)
            if response == .alertFirstButtonReturn, let title = popUp.titleOfSelectedItem { return title }
            return NSNull()
        case "openFile":
            let panel = NSOpenPanel()
            let types = ((arguments.first as? [String: Any])?["types"] as? [Any])?.compactMap { UTType(filenameExtension: "\($0)") } ?? []
            if !types.isEmpty { panel.allowedContentTypes = types }
            guard let url = await chooseOpen(panel, window?.window), let contents = try? String(contentsOf: url, encoding: .utf8) else { return NSNull() }
            return contents
        case "saveFile":
            let panel = NSSavePanel()
            if let name = (arguments.first as? [String: Any])?["suggestedName"] as? String { panel.nameFieldStringValue = name }
            guard let url = await chooseSave(panel, window?.window) else { return NSNull() }
            let token = UUID().uuidString
            writers[token] = url
            return token
        case "write":
            guard let url = writers[Self.text(arguments, 0)] else { return NSNull() }
            try? Data(Self.text(arguments, 1).utf8).write(to: url, options: .atomic)
            return NSNull()
        case "progress":
            progress.title = Self.text(arguments, 0)
            progress.fraction = 0
            progress.text = ""
            if progressSheet == nil, let window {
                progressSheet = window.presentSheet("sheet.scriptProgress") { [progress] _ in ScriptProgressSheet(model: progress) }
            }
            return NSNull()
        case "progressDone":
            endProgress()
            return NSNull()
        case "merge":
            return await merge(arguments.first as? [String: Any] ?? [:])
        default:
            return nil
        }
    }

    func update(_ fraction: Double, _ text: String) {
        progress.fraction = fraction
        progress.text = text
    }

    func endProgress() {
        if let sheet = progressSheet { sheet.sheetParent?.endSheet(sheet) }
        progressSheet = nil
    }

    @discardableResult
    private func alert(_ message: String, buttons: [String], accessory: NSView? = nil) async -> (response: NSApplication.ModalResponse, alert: NSAlert) {
        let alert = NSAlert()
        alert.messageText = message
        for button in buttons { alert.addButton(withTitle: button) }
        alert.accessoryView = accessory
        return (await runAlert(alert, window?.window), alert)
    }

    /// `wt.records.merge({ to, records, ... })`: the merge sheet's merge, run from a script.
    private func merge(_ options: [String: Any]) async -> Any {
        guard let window, let data else { return NSNull() }
        let model = MergeSheetModel(window: window, session: data.session(for: window))
        switch options["to"] as? String {
        case "pdf": model.target = .pdf
        case "printer": model.target = .printer
        default: model.target = .pages
        }
        if let records = options["records"] { model.recordsText = "\(records)" }
        if let pattern = options["fileName"] as? String {
            model.pattern = pattern
            model.oneFile = false
        }
        prepareMerge(model)
        await model.merge()
        return model.message ?? NSNull()
    }
}
