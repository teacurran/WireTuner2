import Foundation

/// How a click or marquee combines with what is selected (selecting.adoc, "To add to or
/// remove from a selection").
enum SelectionMode: Sendable, Equatable {
    /// A plain click or marquee: the result is the selection.
    case replace
    /// Adds without removing (select commands with Shift).
    case add
    /// Shift-click and Shift-marquee: each picked object flips.
    case toggle
    case subtract
}

/// The selection as a value: an ordered set of objects (in the order they were selected,
/// which the Object panel and presence both keep) plus a sub-selection per object.  Pure, so
/// every rule is tested without a window.
struct Selection: Equatable, Sendable {
    private(set) var ids: [SelectionID] = []
    private var members: Set<SelectionID> = []
    /// Points, segments or a text range inside a selected object; never empty, never for an
    /// object that is not in `ids`.
    private(set) var subSelections: [SelectionID: SubSelection] = [:]

    init() {}

    init<S: Sequence>(_ ids: S) where S.Element == SelectionID {
        for id in ids { append(id) }
    }

    static let empty = Selection()

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: SelectionID) -> Bool { members.contains(id) }
    func subSelection(of id: SelectionID) -> SubSelection? { subSelections[id] }

    private mutating func append(_ id: SelectionID) {
        guard members.insert(id).inserted else { return }
        ids.append(id)
    }

    private mutating func remove(_ id: SelectionID) {
        guard members.remove(id) != nil else { return }
        ids.removeAll { $0 == id }
        subSelections[id] = nil
    }

    /// `picked` combined with this selection by `mode`.  `sub` gives the picked objects'
    /// sub-selections (a point click, a marquee over anchors); an object toggled off loses its
    /// sub-selection, one kept by `toggle` because only its points flipped keeps the rest.
    func applying(_ picked: [SelectionID], sub: [SelectionID: SubSelection] = [:], mode: SelectionMode) -> Selection {
        var result = self
        switch mode {
        case .replace:
            result = Selection(picked)
            for (id, subSelection) in sub { result.setSubSelection(subSelection, for: id) }
        case .add:
            for id in picked {
                result.append(id)
                if let subSelection = sub[id] {
                    result.setSubSelection(result.subSelections[id].map { $0.adding(subSelection) } ?? subSelection, for: id)
                }
            }
        case .toggle:
            for id in picked {
                if let subSelection = sub[id], result.contains(id) {
                    // Flipping points inside an object that stays selected.
                    result.setSubSelection(result.subSelections[id].map { $0.toggling(subSelection) } ?? subSelection, for: id)
                } else if result.contains(id) {
                    result.remove(id)
                } else {
                    result.append(id)
                    if let subSelection = sub[id] { result.setSubSelection(subSelection, for: id) }
                }
            }
        case .subtract:
            for id in picked { result.remove(id) }
        }
        return result
    }

    /// Sets (or with an empty value clears) the sub-selection of a selected object; ignored
    /// for an object that is not selected.
    mutating func setSubSelection(_ subSelection: SubSelection?, for id: SelectionID) {
        guard contains(id) else { return }
        subSelections[id] = subSelection.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Everything in `universe` that is not selected now, in `universe`'s order, and nothing
    /// that is (menu:Edit[Select > Invert Selection]).
    func inverted(within universe: [SelectionID]) -> Selection {
        Selection(universe.filter { !contains($0) })
    }

    /// Each id mapped through `transform`, dropping the ones it maps to nil and keeping order
    /// and sub-selections (the selection following remote changes).  `subTransform` maps the
    /// sub-selections the same way.
    func remapped(_ transform: (SelectionID) -> SelectionID?, sub subTransform: (SubSelection) -> SubSelection = { $0 }) -> Selection {
        var result = Selection()
        for id in ids {
            guard let mapped = transform(id) else { continue }
            result.append(mapped)
            if let subSelection = subSelections[id] { result.setSubSelection(subTransform(subSelection), for: mapped) }
        }
        return result
    }

    /// The selection after the top-level items at `removed` were deleted: objects in them
    /// leave, the rest keep being selected at their new index paths.
    func removingItems(at removed: IndexSet) -> Selection {
        remapped({ $0.shifted(afterRemoving: removed) }, sub: { $0.shifted(afterRemoving: removed) })
    }

    /// Only the objects for which `isValid` holds (an object that vanished is dropped).
    func filtered(_ isValid: (SelectionID) -> Bool) -> Selection {
        remapped { isValid($0) ? $0 : nil }
    }
}
