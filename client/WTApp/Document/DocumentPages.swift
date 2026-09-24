import Foundation
import WTCRDT
import WTGeometry
import WTModel
import WTProto

/// Replaces the document's pages with pages of the given rectangles, in page order, as one change
/// ("Set pages"): the live pages are moved and resized onto the first rectangles (their objects
/// stay where they are), pages beyond the list are deleted (their objects stay, on the
/// pasteboard), and missing pages are added.  An empty list deletes every page, so the document
/// reads as the one Letter page of the zero-pages rule.  A new document's first page and the
/// tests' page layouts are written through it.
struct ReplacePageRects: WTModel.Command {
    let rects: [Rect]
    /// The preset every page's geometry names ("" is Custom).
    var preset = ""
    /// False for a new document's page, which is part of its template and not an undo step.
    var recordsUndo = true

    init(_ rects: [Rect], preset: String = "", recordsUndo: Bool = true) {
        self.rects = rects
        self.preset = preset
        self.recordsUndo = recordsUndo
    }

    var label: String { "Set pages" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard rects.allSatisfy({ PageGeometry(width: $0.width, height: $0.height).isValid && $0.origin.isFinite }) else {
            throw PageSetupError.invalidValue("rect")
        }
        let list = PageList(state)
        var ids = list.isSynthesized ? [] : list.pages.map(\.id)
        for id in ids.dropFirst(rects.count) { builder.append(Ops.setDeleted(id)) }
        ids = Array(ids.prefix(rects.count))
        if rects.count > ids.count {
            // New pages through the page commands (their positions in page order), then placed below.
            let first = builder.ops.count
            var counter = builder.nextCounter
            if list.isSynthesized && rects.count == 1 {
                try SetPageGeometry([PageList.synthesizedID], to: geometry(rects[0])).execute(&builder, state: state)
            } else {
                let count = rects.count - ids.count - (list.isSynthesized ? 1 : 0)
                try AddPages(count: count, after: ids.last).execute(&builder, state: state)
            }
            for op in builder.ops[first...] {
                if case .create(let create) = op.op, OpID(create.parent) == WellKnown.pages {
                    ids.append(OpID(counter: counter, replica: builder.replica))
                }
                counter &+= EngineState.counters(op)
            }
        }
        for (id, rect) in zip(ids, rects) {
            builder.append(Ops.set(id, [PageFields.origin, PageFields.geometry], values: PageFields.values {
                $0.origin.x = rect.minX
                $0.origin.y = rect.minY
                $0.geometry = geometry(rect).stored
            }))
        }
    }

    /// A geometry of `rect`'s size naming `preset`.
    func geometry(_ rect: Rect) -> PageGeometry {
        PageGeometry(preset: preset, width: rect.width, height: rect.height)
    }
}

extension ReplacePageRects {
    /// A new document's first page: Letter, centred on the pasteboard (workspace.adoc, "The
    /// pasteboard"), written with the template so there is room to work on every side.
    static let newDocument = ReplacePageRects([Pasteboard.letterPage], preset: "Letter", recordsUndo: false)
}
