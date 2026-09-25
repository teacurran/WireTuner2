import SwiftUI
import WTCRDT
import WTModel
import WTRender

/// The Animation panel's marks in the Layers panel (animation.adoc, "Frames"; WEB-017): with
/// *Show frame numbers* on (the Layers panel menu) each foreground layer that is a frame shows its
/// number when the frames are layers, and during playback the current frame's layer is
/// highlighted.
@MainActor
enum LayerFrames {
    /// The layer of the frame the front window's Animation panel shows, nil when it shows none.
    static var playingLayer: @MainActor (DocumentHandle) -> OpID? = { _ in nil }

    /// Each frame layer's 1-based frame number, when the document's frames are its layers.
    static func numbers(_ document: DocumentHandle) -> [OpID: Int] {
        let info = AnimationInfo(document.state)
        guard info.source == .layers else { return [:] }
        var numbers: [OpID: Int] = [:]
        for (index, frame) in info.frames().enumerated() {
            guard let layer = frame.layers.last.map({ OpID($0) }), numbers[layer] == nil else { continue }
            numbers[layer] = index + 1
        }
        return numbers
    }

    /// The options menu item.
    static func toggleTitle(_ state: LayersPanelState) -> String {
        state.showsFrameNumbers ? "Hide Frame Numbers" : "Show Frame Numbers"
    }

    /// What a layer row shows: its frame number (nil: none) and whether it is the playing frame.
    static func marks(_ layer: OpID, document: DocumentHandle, state: LayersPanelState) -> (number: Int?, playing: Bool) {
        (state.showsFrameNumbers ? numbers(document)[layer] : nil, playingLayer(document) == layer)
    }

    /// The row background: the playing frame's highlight wins over the panel selection's tint.
    static func background(playing: Bool, selected: Bool) -> SwiftUI.Color {
        if playing { return SwiftUI.Color.orange.opacity(0.3) }
        return selected ? SwiftUI.Color.accentColor.opacity(0.18) : SwiftUI.Color.clear
    }
}

/// A frame number beside a layer's name.
struct LayerFrameNumber: View {
    let number: Int?

    var body: some View {
        if let number {
            Text("\(number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("layers.frame.\(number)")
        }
    }
}
