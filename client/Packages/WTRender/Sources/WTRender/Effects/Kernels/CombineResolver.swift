// Combine's operands (FX-048): each member of the group as one filled outline in pasteboard space
// -- a path's effected outline (its own and inherited vector effects applied, open contours
// dropped), a nested derived group's result (a nested Combine combined first), a plain group as the
// union of its members, text as its laid-out glyph outlines, an image as its frame.

import WTGeometry

enum CombineResolver {
    static func outline(of item: DisplayItem) -> FilledPath {
        switch item {
        case .path(let path):
            let chain = EffectPipeline.Chain(path.appearance.liveEffects.filter { $0.target == .object }.map {
                FramedEffect(effect: $0.effect, toEffectSpace: .identity, reference: EffectPipeline.ownBounds(path.path))
            } + path.inheritedEffects)
            let shapes = EffectPipeline.applyVector(chain.vector, to: [EffectShape(contours: path.path.contours)])
            let rule = shapes.lazy.compactMap(\.rule).first ?? path.appearance.fills.first?.rule ?? .nonZero
            let contours = shapes.flatMap(\.contours).filter(\.isClosed).map { $0.applying(path.transform) }
            return FilledPath(contours: contours, fillRule: rule)
        case .fill(let fill):
            return FilledPath(contours: fill.path.contours.filter(\.isClosed).map { $0.applying(fill.transform) }, fillRule: fill.rule)
        case .stroke(let stroke):
            return FilledPath(contours: stroke.path.contours.filter(\.isClosed).map { $0.applying(stroke.transform) })
        case .text(let text):
            let outline = text.glyphRun?.outline ?? DisplayPath(rect: text.bounds)
            return FilledPath(contours: outline.contours.filter(\.isClosed).map { $0.applying(text.transform) })
        case .image(let image):
            return FilledPath(contours: DisplayPath(rect: image.rect).contours.map { $0.applying(image.transform) })
        case .group(let group):
            let members: [DisplayItem] = group.isDerived ? EffectPipeline.derived(group).entries.filter(\.visible).map(\.item) : group.children
            let operands = members.map(outline(of:)).filter { !$0.isEmpty }
            guard !operands.isEmpty else {
                return .empty
            }
            return operands.count == 1 ? operands[0] : Boolean.union(operands)
        }
    }
}
