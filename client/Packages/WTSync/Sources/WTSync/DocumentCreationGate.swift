import Foundation

/// Makes `DocumentService.Create` happen before a document's sync (DOC-019, D-089): a document
/// made on this Mac -- New, New from Template, a duplicate, a foreign file or package opened as a
/// new document, a typeface, a template copy -- is recorded and opened at once, and its `Create`
/// is deferred while offline.  A `SyncClient` given a gate asks it before every Subscribe whether
/// the document is still waiting for its `Create`, and if so creates it first (or waits for the
/// `Create` already running); while that cannot succeed the session ends like any unreachable
/// one and retries after the backoff, the outbox kept.  A `NOT_FOUND` for a document the gate
/// still names waiting is the same wait, not *The document no longer exists*.
///
/// The app's gate is the library's pending uploads (`LibraryModel`); a client without one (tests,
/// documents that were never made here) subscribes at once.
public struct DocumentCreationGate: Sendable {
    /// Whether `documentID` was made on this Mac and the server has not created it yet.
    public var isPending: @Sendable (_ documentID: String) async -> Bool
    /// Creates `documentID` on the server, or waits for the `Create` already running; throws
    /// while it cannot (offline, signed out).  Returning without an error while `isPending`
    /// still holds counts as not created yet.
    public var create: @Sendable (_ documentID: String) async throws -> Void

    public init(isPending: @escaping @Sendable (_ documentID: String) async -> Bool,
                create: @escaping @Sendable (_ documentID: String) async throws -> Void) {
        self.isPending = isPending
        self.create = create
    }

    /// Why a session did not subscribe: the document is still waiting for its `Create`.
    static let waitingCause = "waiting for the document to be created"
}
