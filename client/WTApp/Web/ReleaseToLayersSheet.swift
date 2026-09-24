import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTRender

/// menu:Extensions[Animate > Release to Layers…] (WEB-015's sheet; animation.adoc, "Releasing
/// objects to layers"): *Animate* (Sequence, Build, Drop, Trail with *Trail by*), *Reverse
/// direction*, *Use existing layers* and *Send to back*, remembered between uses; btn:[OK] releases
/// the selection as one change.
@MainActor
@Observable
final class ReleaseToLayersModel {
    enum Mode: String, CaseIterable, Identifiable {
        case sequence, build, drop, trail
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    static let modeKey = "web.release.mode"
    static let trailKey = "web.release.trail"
    static let reverseKey = "web.release.reverse"
    static let existingKey = "web.release.existing"
    static let backKey = "web.release.back"

    @ObservationIgnored weak var window: DocumentWindowController?
    @ObservationIgnored let defaults: UserDefaults
    var mode: Mode
    var trail: Int
    var reverse: Bool
    var useExistingLayers: Bool
    var sendToBack: Bool
    private(set) var message: String?
    @ObservationIgnored var onClose: @MainActor () -> Void = {}

    init(window: DocumentWindowController, preferences: PreferenceStore) {
        self.window = window
        defaults = preferences.defaults
        mode = Mode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .sequence
        trail = max(1, defaults.integer(forKey: Self.trailKey) == 0 ? 2 : defaults.integer(forKey: Self.trailKey))
        reverse = defaults.bool(forKey: Self.reverseKey)
        useExistingLayers = defaults.bool(forKey: Self.existingKey)
        sendToBack = defaults.bool(forKey: Self.backKey)
    }

    var releaseMode: ReleaseMode {
        switch mode {
        case .sequence: .sequence
        case .build: .build
        case .drop: .drop
        case .trail: .trail(trail)
        }
    }

    /// The command for the window's selection.
    var command: ReleaseToLayers? {
        guard let window, window.objectEditing.hasSelection else { return nil }
        return ReleaseToLayers(window.objectEditing.selectedNodes, mode: releaseMode, reverse: reverse, useExistingLayers: useExistingLayers,
                               sendToBack: useExistingLayers && sendToBack, currentLayer: window.objectEditing.activeLayer,
                               textLayout: TextSceneLayout(engine: window.documentHandle.textEngine))
    }

    /// btn:[OK]: the release, one undoable step; the choices are remembered.
    @discardableResult
    func release() async -> Wiretuner_Doc_V1_Change? {
        guard let window, let command else { return nil }
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(trail, forKey: Self.trailKey)
        defaults.set(reverse, forKey: Self.reverseKey)
        defaults.set(useExistingLayers, forKey: Self.existingKey)
        defaults.set(sendToBack, forKey: Self.backKey)
        let change = await window.objectEditing.perform(command).value
        if change == nil {
            message = "Nothing selected can be released to layers."
        } else {
            onClose()
        }
        return change
    }

    func cancel() { onClose() }
}

struct ReleaseToLayersSheet: View {
    @Bindable var model: ReleaseToLayersModel

    static func release(_ model: ReleaseToLayersModel) -> () -> Void { { Task { await model.release() } } }
    static func cancel(_ model: ReleaseToLayersModel) -> () -> Void { { model.cancel() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Animate", selection: $model.mode) {
                ForEach(ReleaseToLayersModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("release.mode")
            if model.mode == .trail {
                Stepper("Trail by \(model.trail)", value: $model.trail, in: 1...100)
            }
            Toggle("Reverse direction", isOn: $model.reverse)
            Toggle("Use existing layers", isOn: $model.useExistingLayers)
            Toggle("Send to back", isOn: $model.sendToBack).disabled(!model.useExistingLayers).padding(.leading, 16)
            if let message = model.message { Text(message).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancel(model)).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.release(model)).keyboardShortcut(.defaultAction).accessibilityIdentifier("release.ok")
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
