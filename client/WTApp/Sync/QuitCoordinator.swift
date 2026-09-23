import AppKit
import Observation
import SwiftUI

/// The quit sheet's state (saving.adoc, "Closing and quitting with changes waiting"): the
/// documents whose changes have not reached the cloud, and whether *Quit When Uploaded* is
/// waiting for them.
@MainActor
@Observable
final class QuitSheetModel {
    enum Choice: Sendable {
        case quitNow, quitWhenUploaded, cancel
    }

    var documents: [WaitingDocument]
    private(set) var isWaiting = false
    @ObservationIgnored var onChoice: @MainActor (Choice) -> Void = { _ in }

    init(documents: [WaitingDocument]) {
        self.documents = documents
    }

    /// "3 documents have changes that haven't reached the cloud yet."
    var headline: String {
        documents.count == 1 ? "1 document has changes that haven't reached the cloud yet."
            : "\(documents.count) documents have changes that haven't reached the cloud yet."
    }

    static let reassurance = "They are safe on this Mac and will upload the next time WireTuner opens."

    func choose(_ choice: Choice) {
        if choice == .quitWhenUploaded { isWaiting = true }
        onChoice(choice)
    }
}

/// The sheet: the rows, then *Quit Now*, *Quit When Uploaded* and *Cancel*; while waiting, a
/// progress line and *Cancel*.
struct QuitSheetView: View {
    let model: QuitSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.headline).font(.headline).accessibilityIdentifier("quit.headline")
            Text(QuitSheetModel.reassurance).font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                ForEach(model.documents) { document in
                    GridRow {
                        Text(document.title)
                        Text(document.detail).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("quit.document.\(document.id)")
                }
            }
            if model.isWaiting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for uploads to finish…")
                    Spacer()
                    Button("Cancel", action: Self.action(model, .cancel)).accessibilityIdentifier("quit.cancel")
                }
            } else {
                HStack {
                    Button("Quit Now", action: Self.action(model, .quitNow)).accessibilityIdentifier("quit.now")
                    Button("Quit When Uploaded", action: Self.action(model, .quitWhenUploaded))
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("quit.whenUploaded")
                    Spacer()
                    Button("Cancel", action: Self.action(model, .cancel))
                        .keyboardShortcut(.cancelAction).accessibilityIdentifier("quit.cancel")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }

    static func action(_ model: QuitSheetModel, _ choice: QuitSheetModel.Choice) -> () -> Void {
        { model.choose(choice) }
    }
}

/// Decides whether the app may quit now (IO-007): with *Warn when quitting with changes waiting*
/// on and any document waiting, it shows the sheet and answers `.terminateLater`; *Quit When
/// Uploaded* then quits as soon as nothing is waiting any more.
@MainActor
final class QuitCoordinator {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("quit-sheet")

    let sessions: DocumentSessions
    /// *Warn when quitting with changes waiting*.
    var warns: @MainActor () -> Bool
    /// Answers the pending `applicationShouldTerminate`; replaceable in tests.
    var reply: @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
    private(set) var model: QuitSheetModel?
    private(set) var window: NSWindow?
    private var token: UUID?

    init(sessions: DocumentSessions, warns: @escaping @MainActor () -> Bool) {
        self.sessions = sessions
        self.warns = warns
    }

    func shouldTerminate() -> NSApplication.TerminateReply {
        let waiting = sessions.waitingDocuments
        guard model == nil else { return .terminateLater }
        guard warns(), !waiting.isEmpty else { return .terminateNow }
        let model = QuitSheetModel(documents: waiting)
        model.onChoice = { [weak self] choice in self?.choose(choice) }
        self.model = model
        let window = NSPanel(contentViewController: NSHostingController(rootView: QuitSheetView(model: model)))
        window.identifier = Self.windowIdentifier
        window.title = "Quit WireTuner"
        window.styleMask = [.titled]
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        return .terminateLater
    }

    func choose(_ choice: QuitSheetModel.Choice) {
        switch choice {
        case .quitNow: finish(true)
        case .cancel: finish(false)
        case .quitWhenUploaded:
            token = sessions.observe { [weak self] in self?.check() }
            check()
        }
    }

    private func check() {
        guard let model else { return }
        model.documents = sessions.waitingDocuments
        if model.documents.isEmpty { finish(true) }
    }

    private func finish(_ quit: Bool) {
        if let token { sessions.stopObserving(token) }
        token = nil
        window?.orderOut(nil)
        window = nil
        model = nil
        reply(quit)
    }
}
