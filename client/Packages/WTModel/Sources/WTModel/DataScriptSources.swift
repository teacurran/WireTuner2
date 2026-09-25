import Foundation
import Synchronization
import WTCRDT
import WTProto

// The remaining model pieces of DATA-015 (data-merge.adoc, "A script" and "Client"): a script
// chosen from the Scripts folder or a team library is copied into the document when it is picked
// (as symbols are: an identical copy already here is reused), and transform results are cached
// per record so a merge that renders a field many times runs its transform once per value.

/// A script from outside the document, as the *Connect… > Script…* and transform choosers offer
/// it: from this Mac's Scripts folder, or from a team library document.
public struct ExternalScript: Hashable, Sendable {
    public var name: String
    public var source: String
    public var description: String
    /// The team library it comes from (document, script node, the library's head); nil for the
    /// Scripts folder.
    public var library: Wiretuner_Doc_V1_LibrarySource?

    public init(name: String, source: String, description: String = "", library: Wiretuner_Doc_V1_LibrarySource? = nil) {
        self.name = name
        self.source = source
        self.description = description
        self.library = library
    }

    /// The document script that already stands for this one: a live copy of the same library
    /// script (by library document and node) whose source is unchanged, else a live script of
    /// the same source and name (or the free name a copy took).  Nil when it must be copied.
    public func existingCopy(in state: EngineState) -> OpID? {
        let scripts = DocumentScript.list(state)
        if let library, let copy = scripts.first(where: { script in
            script.library.map { $0.documentID == library.documentID && $0.symbol == library.symbol } == true && script.source == source
        }) {
            return copy.id
        }
        // A folder script copied under a free name ("Name 2") is still its copy.
        return scripts.first { script in
            script.source == source && (script.name == name || script.name.hasPrefix(name + " ") && Int(script.name.dropFirst(name.count + 1)) != nil)
        }?.id
    }

    /// The name the copy takes: its own, or "Name 2", "Name 3" ... when a different script holds
    /// that name.
    func freeName(in state: EngineState) -> String {
        let taken = Set(DocumentScript.list(state).map(\.name))
        guard taken.contains(name) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }
}

/// Picking an outside script for a script source or a transform: the script copied into the
/// document's assets (0:9) with its library provenance, unless an identical copy is already here
/// (then nothing is written and `ExternalScript.existingCopy` names it).  "Copy script".
public struct CopyScriptIntoDocument: Command {
    public var script: ExternalScript
    public var label: String { "Copy script" }

    public init(_ script: ExternalScript) {
        self.script = script
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard script.existingCopy(in: state) == nil else { return }
        try SaveScript(name: script.freeName(in: state), source: script.source, description: script.description.isEmpty ? nil : script.description,
                       library: script.library).execute(&builder, state: state)
    }

    /// The document script `change` (this command's, or nil when it wrote nothing) leaves standing
    /// for `script` in `state` (after the change).
    public static func node(for script: ExternalScript, after change: Wiretuner_Doc_V1_Change?, in state: EngineState) -> OpID? {
        change?.createdNodes.first ?? script.existingCopy(in: state)
    }
}

/// Transform results cached per record (data-merge.adoc, "Record resolution"): the base
/// transformer runs once per (script, value, record, field); a transform that throws is not
/// cached, so the report repeats for every record it fails on.  One cache per resolution: a new
/// `RecordSet` build (a changed script, source or mapping) starts empty.
public final class CachingFieldTransformer: FieldTransforming, Sendable {
    struct Key: Hashable {
        var script: OpID
        var value: String?
        var record: [String: String]
        var field: String
    }

    private let base: any FieldTransforming & Sendable
    private let cache = Mutex<[Key: String?]>([:])
    private let counter = Mutex(0)

    public init(_ base: any FieldTransforming & Sendable) {
        self.base = base
    }

    /// How many calls reached the base transformer.
    public var runs: Int { counter.withLock { $0 } }

    public func transform(script: OpID, value: String?, record: [String: String], field: String) throws -> String? {
        let key = Key(script: script, value: value, record: record, field: field)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        counter.withLock { $0 += 1 }
        let result = try base.transform(script: script, value: value, record: record, field: field)
        cache.withLock { $0[key] = .some(result) }
        return result
    }
}
