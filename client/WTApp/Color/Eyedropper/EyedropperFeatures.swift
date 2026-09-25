import AppKit
import WTCRDT
import WTModel
import WTRender

/// The Eyedropper in place of its catalog stub (COLOR-012): its click makes the lifted colour the
/// active well's current colour and loads it into the Color Mixer.
@MainActor
enum EyedropperFeatures {
    /// A click's pick: the current colour of the palette's active well, and the Mixer.
    static func pick(palette: ToolPaletteModel, mixer: ColorMixerModel) -> @MainActor (EyedropperSample) -> Void {
        { sample in
            palette.setCurrent(sample.ref, color: sample.color, for: palette.activeWell)
            if let color = sample.color { mixer.load(color, swatch: ColorResolver.swatch(of: sample.ref)) }
        }
    }

    static func descriptor(palette: ToolPaletteModel, mixer: ColorMixerModel, defaultSpace: @escaping @MainActor @Sendable () -> RenderColor.Space) -> ToolDescriptor {
        let pick = pick(palette: palette, mixer: mixer)
        return ToolCatalog.all.first { $0.id == EyedropperTool.id }!.delivering { EyedropperTool(defaultSpace: defaultSpace, pick: pick) }
    }
}

extension AppDelegate {
    func installEyedropper() {
        let workspace = colors.workspace
        tools.replace(EyedropperFeatures.descriptor(palette: toolPalette, mixer: colors.mixer) { workspace.defaultSpace })
    }
}
