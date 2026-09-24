import Foundation
import WTCRDT
import WTProto

// DATA-011: the `script` node kind (scripting.adoc, "Data model"): JavaScript saved into the
// document under the assets collection (0:9), run as last saved -- `source` is one ATOMIC
// register -- and referenced by data-merge transforms and sources by node id.

/// Register paths of `ScriptProps` (`NodeProps.script` = 241).
public enum ScriptFields {
    public static let kind: UInt32 = 241
    /// The well-known `assets` collection every script node sits under.
    public static let collection = OpID.wellKnown(9)
    public static let name = RegisterPath([kind, 1, 1])
    public static let description = RegisterPath([kind, 2])
    public static let source = RegisterPath([kind, 3])
    public static let library = RegisterPath([kind, 4])
    /// The largest source a script node stores (1 MiB).
    public static let maxSource = 1_048_576

    static func values(_ build: (inout Wiretuner_Doc_V1_ScriptProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        var script = Wiretuner_Doc_V1_ScriptProps()
        build(&script)
        props.script = script
        return props
    }
}

/// One document script as the Scripts menu and the Script Editor's chooser list it.
public struct DocumentScript: Identifiable, Hashable, Sendable {
    public let id: OpID
    public let name: String
    public let description: String
    public let source: String
    /// Copied from a team library (*Update from Library* finds the original through it).
    public let library: Wiretuner_Doc_V1_LibrarySource?

    /// The live scripts of the document, in sibling order.
    public static func list(_ state: EngineState) -> [DocumentScript] {
        state.liveChildren(ScriptFields.collection).compactMap { script($0, in: state) }
    }

    /// The live script node `node`, or nil.
    public static func script(_ node: OpID, in state: EngineState) -> DocumentScript? {
        guard DataModel.isScript(node, in: state) else { return nil }
        let props = state.props(node).script
        return DocumentScript(id: node, name: props.common.name, description: props.description_p, source: props.source,
                              library: props.hasLibrary ? props.library : nil)
    }
}

/// Why a script command could not build its change.
public enum ScriptEditError: Error, Hashable, Sendable {
    /// The node is not a script node.
    case notAScript(OpID)
    /// The source is larger than 1 MiB.
    case tooLarge(Int)
}

/// btn:[Save to Document] and btn:[Save] on a document script: writes the whole source (ATOMIC)
/// and, for a new script, creates the node under the assets collection with its name.  "Save
/// script".
public struct SaveScript: Command {
    /// The script to save over; nil creates one.
    public var node: OpID?
    public var name: String
    public var source: String
    public var description: String?
    public var library: Wiretuner_Doc_V1_LibrarySource?
    public var label: String { "Save script" }

    public init(_ node: OpID? = nil, name: String, source: String, description: String? = nil, library: Wiretuner_Doc_V1_LibrarySource? = nil) {
        self.node = node
        self.name = name
        self.source = source
        self.description = description
        self.library = library
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let size = source.utf8.count
        guard size <= ScriptFields.maxSource else { throw ScriptEditError.tooLarge(size) }
        let description = self.description.map { String($0.prefix(1024)) }
        guard let node else {
            let last = state.store.children(ScriptFields.collection).last.flatMap { state.store.placement($0)?.position }
            let key = try PathEditing.keys(between: last, and: nil, count: 1)[0]
            builder.append(Ops.create(parent: ScriptFields.collection, position: key, props: ScriptFields.values {
                $0.common.name = String(name.prefix(256))
                $0.source = source
                if let description { $0.description_p = description }
                if let library { $0.library = library }
            }))
            return
        }
        guard state.store.kind(node) == ScriptFields.kind else { throw ScriptEditError.notAScript(node) }
        var paths = [ScriptFields.source]
        let current = state.props(node).script
        if current.common.name != name { paths.append(ScriptFields.name) }
        if let description, description != current.description_p { paths.append(ScriptFields.description) }
        builder.append(Ops.set(node, paths, values: ScriptFields.values {
            $0.common.name = String(name.prefix(256))
            $0.source = source
            $0.description_p = description ?? ""
        }))
    }
}

/// Renames a document script (an independent register from its source), "Rename script".
public struct RenameScript: Command {
    public var node: OpID
    public var name: String
    public var label: String { "Rename script" }

    public init(_ node: OpID, to name: String) {
        self.node = node
        self.name = name
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.store.kind(node) == ScriptFields.kind else { throw ScriptEditError.notAScript(node) }
        builder.append(Ops.set(node, [ScriptFields.name], values: ScriptFields.values { $0.common.name = String(name.prefix(256)) }))
    }
}

/// Deletes a document script, "Delete script".  A transform naming it reads as none and a
/// script source fails with "script missing"; *Restore* brings it back with its source.
public struct DeleteScript: Command {
    public var node: OpID
    public var label: String { "Delete script" }

    public init(_ node: OpID) {
        self.node = node
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard DataModel.isScript(node, in: state) else { throw ScriptEditError.notAScript(node) }
        builder.append(Ops.setDeleted(node))
    }
}
