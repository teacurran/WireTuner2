import Foundation
import WTCRDT

/// A link to a document, an object in it or a comment thread (inspect.adoc, "Data model";
/// COLLAB-038):
///
/// ----
/// wiretuner://doc/<document id>/node/<counter>-<replica>
/// wiretuner://doc/<document id>/thread/<counter>-<replica>
/// wiretuner://doc/<document id>
/// ----
///
/// `<counter>-<replica>` is the node's `OpId` in decimal (both unsigned).  The API's
/// `https://<host>/d/<document id>` form (`/n/<id>` for a node, `/t/<id>` for a thread) redirects to
/// the same `wiretuner://` URL and is read here too, as is the Comments panel's link as first built
/// (`wiretuner://document/<id>?thread=<counter>.<replica>`).  A URL, not document data.
public struct DeepLink: Hashable, Sendable, CustomStringConvertible {
    /// What in the document the link points at.
    public enum Target: Hashable, Sendable {
        case document
        case node(OpID)
        case thread(OpID)
    }

    public static let scheme = "wiretuner"

    public var documentID: String
    public var target: Target

    public init(documentID: String, target: Target = .document) {
        self.documentID = documentID
        self.target = target
    }

    /// The node the link points at (an object or a thread), nil for a document link.
    public var node: OpID? {
        switch target {
        case .document: nil
        case .node(let id), .thread(let id): id
        }
    }

    /// The `wiretuner://` URL.
    public var url: URL { URL(string: description)! }

    public var description: String {
        let base = "\(Self.scheme)://doc/\(documentID)"
        switch target {
        case .document: return base
        case .node(let id): return "\(base)/node/\(Self.format(id))"
        case .thread(let id): return "\(base)/thread/\(Self.format(id))"
        }
    }

    /// The API's web form on `host` (for mail clients that refuse custom schemes).
    public func webURL(host: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        switch target {
        case .document: components.path = "/d/\(documentID)"
        case .node(let id): components.path = "/d/\(documentID)/n/\(Self.format(id))"
        case .thread(let id): components.path = "/d/\(documentID)/t/\(Self.format(id))"
        }
        return components.url
    }

    /// `counter-replica` in decimal.
    public static func format(_ id: OpID) -> String { "\(id.counter)-\(id.replica)" }

    /// The id `counter-replica` names; nil when it is not two unsigned decimals.
    public static func parse(id text: some StringProtocol, separator: Character = "-") -> OpID? {
        let parts = text.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) }),
              let counter = UInt64(parts[0]), let replica = UInt64(parts[1]) else { return nil }
        return OpID(counter: counter, replica: replica)
    }

    /// Whether `id` can be a document id in a link: letters, digits, `-` and `_`.
    static func isDocumentID(_ id: some StringProtocol) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    /// The link `url` is; nil for any other URL (an invitation, the sign-in callback).
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased() else { return nil }
        let path = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        switch scheme {
        case Self.scheme:
            let host = components.host?.lowercased()
            if host == "document", path.count == 1, Self.isDocumentID(path[0]) {
                // The Comments panel's link as first built.
                let thread = components.queryItems?.first { $0.name == "thread" }?.value.flatMap { Self.parse(id: $0, separator: ".") }
                self.init(documentID: String(path[0]), target: thread.map(Target.thread) ?? .document)
                return
            }
            guard host == "doc" else { return nil }
            self.init(path: path, node: "node", thread: "thread")
        case "https", "http":
            guard path.first == "d" else { return nil }
            self.init(path: Array(path.dropFirst()), node: "n", thread: "t")
        default:
            return nil
        }
    }

    /// `<document>`, `<document>/<node word>/<id>` or `<document>/<thread word>/<id>`.
    private init?(path: [Substring], node: String, thread: String) {
        guard let document = path.first, Self.isDocumentID(document) else { return nil }
        switch path.count {
        case 1:
            self.init(documentID: String(document))
        case 3:
            guard let id = Self.parse(id: path[2]) else { return nil }
            if path[1] == node {
                self.init(documentID: String(document), target: .node(id))
            } else if path[1] == thread {
                self.init(documentID: String(document), target: .thread(id))
            } else {
                return nil
            }
        default:
            return nil
        }
    }
}

/// What opening a link does once its document is open (inspect.adoc, "Offline behavior"): select
/// the object, say it was deleted, or wait for the document to catch up -- a node the store has not
/// received yet may arrive with the changes the client is behind by, so nothing is decided about a
/// node while the session is still catching up, and a live node is selected only after it has.
public enum DeepLinkLanding: Equatable, Sendable {
    /// Catching up: decide again when the session has.
    case wait
    /// The document alone (a document link).
    case document
    /// Select the object (live).
    case select(OpID)
    /// Open the thread (live).
    case openThread(OpID)
    /// "That object was deleted".
    case deleted(OpID)
    /// Caught up (or offline) and the node is not in the document: "That object isn't in this
    /// document yet".
    case notReceived(OpID)

    /// The landing of `link` in `state`; `caughtUp` is whether the session has applied the log to its
    /// head (or cannot: offline, or a document without a session).
    public static func decide(_ link: DeepLink, in state: EngineState, caughtUp: Bool) -> DeepLinkLanding {
        guard let node = link.node else { return .document }
        guard caughtUp else { return .wait }
        guard state.store.exists(node) else { return .notReceived(node) }
        if case .thread = link.target {
            return CommentThreadModel(state)[node] != nil ? .openThread(node) : .deleted(node)
        }
        return state.isLive(node) ? .select(node) : .deleted(node)
    }
}
