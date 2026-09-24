import SwiftUI
import WTModel

/// The Object panel sections of the effects epic: the blend section (FX-028) and the extrusion
/// pages (FX-021), each shown while every selected object is of its kind.
@MainActor
enum EffectSections {
    static func register(into registry: InspectorRegistry) {
        registry.register(InspectorSection(id: "blend", order: 70, kinds: [.blend]) { panel in
            BlendSectionModel(panel).map { AnyView(BlendSectionView(model: $0)) }
        })
        registry.register(InspectorSection(id: "extrude", order: 71, kinds: [.extrude]) { panel in
            ExtrudeSectionModel(panel).map { AnyView(ExtrudeSectionView(model: $0)) }
        })
    }
}
