import WTCRDT
import WTProto

/// The zero-pages case of DOC-006 (pages.adoc, "Merge semantics"): the one way a document reaches
/// no live page is both sides removing different pages of a two-page document concurrently, each
/// legal locally.  The merged state reads as one Letter page (`PageList.isSynthesized`) and the
/// first command that touches pages writes it; the review sheet adds the entry "All pages were
/// removed; a page was added" so both users learn what happened.  This is the model half: the
/// detection the reconcile measurement (WTSync's `Divergence`) calls with the two sides' changes.
public enum ZeroPages {
    /// The review entry's text.
    public static let reviewMessage = "All pages were removed; a page was added."

    /// Whether `merged` has no live page because `local` and `remote` each deleted pages that
    /// `base` (the state both started from) held live.
    public static func removedOnBothSides(base: EngineState, local: [Wiretuner_Doc_V1_Change], remote: [Wiretuner_Doc_V1_Change],
                                          merged: EngineState) -> Bool {
        guard PageList(merged).isSynthesized, !PageList(base).isSynthesized else { return false }
        return !deletedPages(local, in: base).isEmpty && !deletedPages(remote, in: base).isEmpty
    }

    /// The same without the base state, as the reconcile measurement sees it (only the merged
    /// state and both sides' changes; DOC-006 and DOC-031): `merged` has no live page, and each
    /// side deleted a page -- still deleted in `merged` -- that the other did not, so neither side
    /// alone removed every page (which a local command refuses) and a later restore counts for nothing.
    public static func removedOnBothSides(local: [Wiretuner_Doc_V1_Change], remote: [Wiretuner_Doc_V1_Change], merged: EngineState) -> Bool {
        guard PageList(merged).isSynthesized else { return false }
        let mine = deletedPageIDs(local, in: merged)
        let theirs = deletedPageIDs(remote, in: merged)
        return !mine.subtracting(theirs).isEmpty && !theirs.subtracting(mine).isEmpty
    }

    /// The pages of `state` that `changes` delete and that are still deleted there.
    static func deletedPageIDs(_ changes: [Wiretuner_Doc_V1_Change], in state: EngineState) -> Set<OpID> {
        var result: Set<OpID> = []
        for change in changes {
            for op in change.ops {
                guard case .setDeleted(let delete)? = op.op, delete.deleted else { continue }
                let node = OpID(delete.node)
                if state.store.kind(node) == PageFields.kind, state.store.deleted(node)?.current.value == true { result.insert(node) }
            }
        }
        return result
    }

    /// The pages of `state` (live there) that `changes` delete.
    static func deletedPages(_ changes: [Wiretuner_Doc_V1_Change], in state: EngineState) -> Set<OpID> {
        var result: Set<OpID> = []
        for change in changes {
            for op in change.ops {
                guard case .setDeleted(let delete)? = op.op, delete.deleted else { continue }
                let node = OpID(delete.node)
                if state.store.kind(node) == PageFields.kind, state.isLive(node) { result.insert(node) }
            }
        }
        return result
    }
}
