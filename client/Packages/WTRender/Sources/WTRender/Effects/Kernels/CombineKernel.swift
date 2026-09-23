// Combine (FX-048): a group's members folded in stacking order, bottom first, with GEO-002 --
// Union, Subtract (the bottom member minus every member above it, as Punch), Intersect, and Exclude
// (the regions covered an odd number of times: exclusive-or folded pairwise, which for two members
// is the union minus the intersection).  Operands arrive in pasteboard space with open contours
// already dropped; the result is normalized.

import WTGeometry

enum CombineKernel {
    static func combine(_ operands: [FilledPath], operation: LiveEffect.Combine.Operation) -> FilledPath {
        let live = operands.filter { !$0.isEmpty }
        guard let first = live.first else {
            return .empty
        }
        guard live.count > 1 else {
            return operation == .intersect && operands.count > live.count ? .empty : Boolean.normalize(first)
        }
        switch operation {
        case .union:
            return Boolean.union(live)
        case .subtract:
            guard !operands[0].isEmpty else {
                return .empty
            }
            return Boolean.subtracting(first, Boolean.union(Array(live.dropFirst())))
        case .intersect:
            guard live.count == operands.count else {
                return .empty
            }
            return Boolean.intersection(live)
        case .exclude:
            return Boolean.normalize(live.dropFirst().reduce(first) { Boolean.exclusiveOr($0, $1) })
        }
    }
}
