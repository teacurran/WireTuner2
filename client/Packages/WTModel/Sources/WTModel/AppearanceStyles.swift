import WTProto
import WTRender

// WTGeometry and WTRender both name a `LineCap` and a `LineJoin`; this file imports WTRender only,
// so the names here are the display list's.
extension Appearances {
    static func cap(_ cap: Wiretuner_Doc_V1_LineCap) -> LineCap {
        switch cap {
        case .round: .round
        case .square: .square
        default: .butt
        }
    }

    static func join(_ join: Wiretuner_Doc_V1_LineJoin) -> LineJoin {
        switch join {
        case .round: .round
        case .bevel: .bevel
        default: .miter
        }
    }
}
