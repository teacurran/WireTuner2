// OBJ-028's and DOC-011's reference cases: a clip group drawn as WTModel's `ClipRendering` lays it
// out (the clip path's fill, the contents clipped to its outline, its stroke on top) and master
// content on a child page (an inert group, clipped to the bleed rectangle as print and export
// draw it).  They join `ReferenceCorpus.cases`, so they have goldens at 1× and 4×, a bitmap/PDF
// agreement check and REND-007's Metal/Core Graphics tile parity.

import WTGeometry
@testable import WTRender

enum ClipMasterCorpus {
    typealias C = ReferenceCorpus

    /// A rotated square clip path (orange fill, 3 pt black stroke) over a cyan disc and a
    /// magenta bar that stick out of it, in the three slots.
    static var clipGroup: DisplayItem {
        let place = AffineTransform.rotation(radians: .pi / 9).concatenating(.translation(x: 40, y: 12))
        let shape = DisplayPath(rect: Rect(x: 0, y: 0, width: 44, height: 44))
        let fill = C.path(shape, [C.fill(C.orange)]).transformed(by: place)
        let stroke = C.path(shape, [C.stroke(.black, width: 3)]).transformed(by: place)
        let contents = GroupItem(children: [
            C.path(DisplayPath(ellipseIn: Rect(x: 20, y: 20, width: 50, height: 50)), [C.fill(C.cyan)]),
            C.path(DisplayPath(rect: Rect(x: 0, y: 44, width: 120, height: 10)), [C.fill(C.magenta)]),
        ], clip: shape, transform: place)
        return .group(GroupItem(children: [fill, .group(contents), stroke]))
    }

    /// Master content (a yellow band and a black frame) on a child page at (8, 8), clipped to a
    /// bleed rectangle 4 pt outside a 60 × 60 page, as an inert group.
    static var masterContent: DisplayItem {
        var group = GroupItem(children: [
            C.path(DisplayPath(rect: Rect(x: -10, y: 30, width: 100, height: 16)), [C.fill(C.yellow)]),
            C.path(DisplayPath(rect: Rect(x: 2, y: 2, width: 56, height: 56)), [C.stroke(.black, width: 2)]),
        ].map { $0.transformed(by: .translation(x: 8, y: 8)) }, clip: DisplayPath(rect: Rect(x: 4, y: 4, width: 68, height: 68)))
        group.inert = true
        return .group(group)
    }

    static let cases: [ReferenceCase] = [
        ReferenceCase(name: "clipGroupSlots", list: C.list([clipGroup])),
        ReferenceCase(name: "masterContentOnAChild", list: C.list([
            masterContent,
            C.path(DisplayPath(ellipseIn: Rect(x: 30, y: 20, width: 30, height: 30)), [C.fill(C.cyan)]),
        ])),
    ]
}
