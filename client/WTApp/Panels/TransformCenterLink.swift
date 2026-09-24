import Foundation
import Observation
import WTGeometry

/// Keeps the Transform panel's centre fields and the transform handles' centre together
/// (transforming.adoc, "The Transform panel": "Set the center ... by dragging the center point of
/// the transform handles"; OBJ-033).  The Pointer tool of each document's window registers what
/// its handles' centre is and how to move it; the panel reads it on every render (`revision`
/// changes whenever the centre may have) and writes a typed centre back.
@MainActor
@Observable
final class TransformCenterLink {
    static let shared = TransformCenterLink()

    struct Endpoint {
        /// The handles' centre, nil while they are hidden.
        var center: @MainActor () -> Point?
        /// Moves the handles' centre; false while they are hidden.
        var move: @MainActor (Point) -> Bool
    }

    private(set) var revision = 0
    @ObservationIgnored private var endpoints: [ObjectIdentifier: Endpoint] = [:]

    init() {}

    func register(_ endpoint: Endpoint, for document: DocumentHandle) {
        endpoints[ObjectIdentifier(document)] = endpoint
        touch()
    }

    func unregister(_ document: DocumentHandle) {
        guard endpoints.removeValue(forKey: ObjectIdentifier(document)) != nil else { return }
        touch()
    }

    /// The handles' centre in `document`'s window, while they are shown.
    func center(for document: DocumentHandle) -> Point? {
        endpoints[ObjectIdentifier(document)]?.center()
    }

    /// Moves the handles' centre in `document`'s window; false when no handles are shown.
    @discardableResult
    func move(to point: Point, for document: DocumentHandle) -> Bool {
        guard let endpoint = endpoints[ObjectIdentifier(document)], endpoint.move(point) else { return false }
        touch()
        return true
    }

    /// The centre may have changed (handles shown, hidden, dragged or following the selection).
    func touch() {
        revision &+= 1
    }
}
