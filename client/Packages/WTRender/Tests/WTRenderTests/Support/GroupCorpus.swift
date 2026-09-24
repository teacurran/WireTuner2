// OBJ-017's reference case: a group's *Transform as unit* off and on.  It joins
// `ReferenceCorpus.cases`, so it has goldens at 1× and 4×, a bitmap/PDF agreement check and
// REND-007's Metal/Core Graphics tile parity.

import WTGeometry
@testable import WTRender
import struct WTRender.StrokeStyle

enum GroupCorpus {
    typealias C = ReferenceCorpus

    /// A rectangle and a dashed zigzag with 1 pt strokes in a group scaled 300% and moved to
    /// `origin`, as the display-list builder places it (`GroupStrokes`).
    static func group(at origin: Vector, asUnit: Bool) -> DisplayItem {
        let matrix = AffineTransform.scale(3).concatenating(.translation(origin))
        let members: [DisplayItem] = [
            C.path(DisplayPath(rect: Rect(x: 0, y: 12, width: 14, height: 9)), [C.fill(C.orange), C.stroke(.black, width: 1)]),
            C.path(C.zigzag(x: 0, y: 1, width: 14, height: 6), [C.stroke(C.cyan, width: 1, dash: [2, 1])]),
        ].map { $0.transformed(by: matrix) }
        return .group(GroupItem(children: GroupStrokes.children(members, groupTransform: matrix, mode: GroupStrokeMode(transformAsUnit: asUnit))))
    }

    static let cases: [ReferenceCase] = [
        ReferenceCase(name: "groupTransformAsUnit", list: C.list([
            group(at: Vector(dx: 6, dy: 12), asUnit: false),
            group(at: Vector(dx: 70, dy: 12), asUnit: true),
        ])),
    ]
}
