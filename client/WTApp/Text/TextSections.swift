import SwiftUI
import WTModel

/// The text sections of the Object panel beyond the Character section (TYPE-020): the *Effect*
/// pop-up under it (TYPE-037), the *Text Block* section (TYPE-006) and the *Text on path* section
/// (TYPE-043).
@MainActor
enum TextSections {
    static func register(into registry: InspectorRegistry) {
        registry.register(InspectorSection(id: "textEffect", order: 61, kinds: [.text]) { model in
            model.textEffect.map { AnyView(TextEffectSectionView(section: $0, model: model)) }
        })
        registry.register(InspectorSection(id: "textBlock", order: 62, kinds: [.text]) { model in
            model.textBlock.map { AnyView(TextBlockSectionView(section: $0, model: model)) }
        })
        registry.register(InspectorSection(id: "textOnPath", order: 63, kinds: [.text]) { model in
            model.textOnPath.map { AnyView(TextOnPathSectionView(section: $0, model: model)) }
        })
    }
}
