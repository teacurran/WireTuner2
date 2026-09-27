import AppKit
import WTCRDT
import WTModel

// DOC-026's rest (scripting.adoc, "AppleScript"): the Text suite (a text block's paragraphs,
// words and characters with contents, font, size, leading and colour), the document's units and
// grid size, pages' and master pages' guides, and `make new layer`.  As in
// `ScriptableObjects.swift`, reads go through `WTModel.ScriptObjects` and every set runs one
// labelled command ("Script: set size"), one change and one undo step.

// MARK: Text suite

/// A range of a text block's text (`text range`): element `index` of `unit`, found again from the
/// text on every read, so it follows remote edits as an AppleScript reference does.
@objc(WTScriptTextRange)
@MainActor
class WTScriptTextRange: NSObject {
    let block: WTScriptTextBlock
    let index: Int

    class var unit: ScriptObjects.TextUnit { .text }
    /// The text block's element key.
    class var containerKey: String { "" }

    required init(block: WTScriptTextBlock, index: Int) {
        self.block = block
        self.index = index
    }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        MainActor.assumeIsolated { SpecifierBox(specifier) }.value
    }

    private var specifier: NSScriptObjectSpecifier? {
        guard let container = NSScriptClassDescription(for: WTScriptTextBlock.self) else { return nil }
        return NSIndexSpecifier(containerClassDescription: container, containerSpecifier: block.objectSpecifier, key: Self.containerKey, index: index)
    }

    @objc var scriptContents: String {
        get { block.readText(Self.unit, index, "contents") as? String ?? "" }
        set { block.writeText(Self.unit, index, "contents", newValue, name: "contents") }
    }

    @objc var scriptFont: String {
        get { block.readText(Self.unit, index, "font") as? String ?? "" }
        set { block.writeText(Self.unit, index, "font", newValue, name: "font") }
    }

    @objc var scriptSize: Double {
        get { block.readText(Self.unit, index, "size") as? Double ?? 0 }
        set { block.writeText(Self.unit, index, "size", NSNumber(value: newValue), name: "size") }
    }

    @objc var scriptLeading: Double {
        get { block.readText(Self.unit, index, "leading") as? Double ?? 0 }
        set { block.writeText(Self.unit, index, "leading", NSNumber(value: newValue), name: "leading") }
    }

    @objc var scriptColor: [Int] {
        get { WTScriptTextBlock.appleScriptColor(block.readText(Self.unit, index, "color")) }
        set { block.writeText(Self.unit, index, "color", WTScriptTextBlock.modelColor(newValue), name: "color") }
    }
}

@objc(WTScriptParagraph) @MainActor final class WTScriptParagraph: WTScriptTextRange {
    override class var unit: ScriptObjects.TextUnit { .paragraph }
    override class var containerKey: String { "scriptParagraphs" }
}

@objc(WTScriptWord) @MainActor final class WTScriptWord: WTScriptTextRange {
    override class var unit: ScriptObjects.TextUnit { .word }
    override class var containerKey: String { "scriptWords" }
}

@objc(WTScriptCharacter) @MainActor final class WTScriptCharacter: WTScriptTextRange {
    override class var unit: ScriptObjects.TextUnit { .character }
    override class var containerKey: String { "scriptCharacters" }
}

extension WTScriptTextBlock {
    /// `{red, green, blue}` 0...65535 from the model's sRGB 0...1.
    static func appleScriptColor(_ value: Any?) -> [Int] {
        ((value as? [Double]) ?? []).map { Int(($0 * 65535).rounded()) }
    }

    /// The model's 0...1 components from AppleScript's 0...65535 (a bad list stays bad, so the
    /// model refuses it).
    static func modelColor(_ value: [Int]) -> [Any] {
        value.map { NSNumber(value: Double($0) / 65535) }
    }

    func readText(_ unit: ScriptObjects.TextUnit, _ index: Int, _ property: String) -> Any? {
        node.flatMap { ScriptObjects.textGet($0, unit, index, property, in: state) }
    }

    /// Sets `property` of element `index` of `unit`, labelled "Script: set <name>".
    func writeText(_ unit: ScriptObjects.TextUnit, _ index: Int, _ property: String, _ value: Any?, name: String) {
        guard let node, let handle = document?.handle else { return }
        do {
            let edit = try ScriptObjects.textSetting(node, unit, index, property, to: value, in: state)
            ScriptRun.perform(edit.command, label: "set \(name)", on: handle)
        } catch {
            ScriptRun.fail(error)
        }
    }

    private func ranges<T: WTScriptTextRange>(_ type: T.Type) -> [T] {
        guard let node else { return [] }
        return (0..<ScriptObjects.textCount(T.unit, of: node, in: state)).map { T(block: self, index: $0) }
    }

    @objc var scriptParagraphs: [WTScriptParagraph] { ranges(WTScriptParagraph.self) }
    @objc var scriptWords: [WTScriptWord] { ranges(WTScriptWord.self) }
    @objc var scriptCharacters: [WTScriptCharacter] { ranges(WTScriptCharacter.self) }

    // The whole text's formatting (the first character's on read, all of it on set).

    @objc var scriptFont: String {
        get { readText(.text, 0, "font") as? String ?? "" }
        set { writeText(.text, 0, "font", newValue, name: "font") }
    }

    @objc var scriptSize: Double {
        get { readText(.text, 0, "size") as? Double ?? 0 }
        set { writeText(.text, 0, "size", NSNumber(value: newValue), name: "size") }
    }

    @objc var scriptLeading: Double {
        get { readText(.text, 0, "leading") as? Double ?? 0 }
        set { writeText(.text, 0, "leading", NSNumber(value: newValue), name: "leading") }
    }

    @objc var scriptColor: [Int] {
        get { Self.appleScriptColor(readText(.text, 0, "color")) }
        set { writeText(.text, 0, "color", Self.modelColor(newValue), name: "color") }
    }
}

// MARK: Document setup

extension WTScriptDocument {
    /// Sets document property `property`, labelled "Script: set <name>".
    private func writeSetting(_ property: String, _ value: Any?, name: String) {
        guard let handle else { return }
        do {
            ScriptRun.perform(try ScriptObjects.documentSetting(property, to: value, in: state).command, label: "set \(name)", on: handle)
        } catch {
            ScriptRun.fail(error)
        }
    }

    @objc var scriptUnits: String {
        get { ScriptObjects.documentGet("units", in: state) as? String ?? "" }
        set { writeSetting("units", newValue, name: "units") }
    }

    @objc var scriptGridSize: Double {
        get { ScriptObjects.documentGet("gridSize", in: state) as? Double ?? 0 }
        set { writeSetting("gridSize", NSNumber(value: newValue), name: "grid size") }
    }

    /// `make new layer [with properties {name: …}]`: a layer on top of the stack.
    @objc(insertInScriptLayers:)
    func insertLayer(_ layer: WTScriptLayer) {
        guard let handle else { return }
        do {
            let command = try ScriptObjects.creating("layer", ["name": layer.pendingName ?? ""])
            ScriptRun.perform(command, label: "make layer", on: handle) { [weak self] change in
                guard let self, let id = change?.createdNodes.first else { return nil }
                layer.bind(document: self, node: id)
                return layer
            }
        } catch {
            ScriptRun.fail(error)
        }
    }

    @objc(insertObject:inScriptLayersAtIndex:)
    func insertLayer(_ layer: WTScriptLayer, at index: Int) { insertLayer(layer) }
}

// MARK: Guides

/// A ruler guide (`guide`) of a page or master page, addressed by its element id.
@objc(WTScriptGuide)
@MainActor
final class WTScriptGuide: NSObject {
    private(set) var owner: WTScriptNode?
    private(set) var guide: OpID?
    /// `make new guide with properties {orientation: …, position: …}` before it exists.
    var pendingOrientation: String?
    var pendingPosition: Double?

    init(owner: WTScriptNode, guide: OpID) {
        self.owner = owner
        self.guide = guide
    }

    override init() {}

    func bind(owner: WTScriptNode, guide: OpID) {
        self.owner = owner
        self.guide = guide
    }

    @objc var uniqueID: String { guide.map(ScriptObjects.string) ?? "" }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        MainActor.assumeIsolated { SpecifierBox(specifier) }.value
    }

    private var specifier: NSScriptObjectSpecifier? {
        guard let owner, let container = NSScriptClassDescription(for: type(of: owner)) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: container, containerSpecifier: owner.objectSpecifier, key: "scriptGuides", uniqueID: uniqueID)
    }

    private func read(_ property: String) -> Any? {
        guard let owner, let page = owner.node, let guide else { return nil }
        return ScriptObjects.guideGet(guide, on: page, property, in: owner.state)
    }

    @objc var scriptOrientation: String {
        get { read("orientation") as? String ?? pendingOrientation ?? "" }
        set {
            guard guide != nil else { return pendingOrientation = newValue }
            write("orientation", newValue)
        }
    }

    @objc var scriptPosition: Double {
        get { read("position") as? Double ?? pendingPosition ?? 0 }
        set {
            guard guide != nil else { return pendingPosition = newValue }
            write("position", NSNumber(value: newValue))
        }
    }

    private func write(_ property: String, _ value: Any?) {
        guard let owner, let page = owner.node, let guide, let handle = owner.document?.handle else { return }
        do {
            let edit = try ScriptObjects.guideSetting(guide, on: page, property, to: value, in: owner.state)
            ScriptRun.perform(edit.command, label: "set guide \(property)", on: handle)
        } catch {
            ScriptRun.fail(error)
        }
    }
}

extension WTScriptNode {
    /// The guides of this page or master page.
    func guides() -> [WTScriptGuide] {
        guard let node else { return [] }
        return ScriptObjects.guides(of: node, in: state).map { WTScriptGuide(owner: self, guide: $0.id) }
    }

    /// `make new guide at end of guides of page 1 with properties {orientation: "vertical", position: 72}`.
    func insertGuide(_ guide: WTScriptGuide) {
        guard let node, let handle = document?.handle else { return }
        do {
            let command = try ScriptObjects.addingGuide(on: node, orientation: guide.pendingOrientation ?? "horizontal", at: guide.pendingPosition.map(NSNumber.init(value:))).command
            let before = Set(ScriptObjects.guides(of: node, in: state).flatMap(\.ids))
            ScriptRun.perform(command, label: "make guide", on: handle) { [weak self] _ in
                guard let self, let added = ScriptObjects.guides(of: node, in: state).first(where: { !before.contains($0.id) }) else { return nil }
                guide.bind(owner: self, guide: added.id)
                return guide
            }
        } catch {
            ScriptRun.fail(error)
        }
    }

    /// `delete guide 1 of page 1`.
    func removeGuide(at index: Int) {
        let guides = guides()
        guard let node, let handle = document?.handle, guides.indices.contains(index), let guide = guides[index].guide else {
            return ScriptRun.fail(ScriptFailure(ScriptFailure.noSuchObject, "No such guide"))
        }
        do {
            ScriptRun.perform(try ScriptObjects.removingGuide(guide, on: node, in: state).command, label: "delete guide", on: handle)
        } catch {
            ScriptRun.fail(error)
        }
    }
}

extension WTScriptPage {
    @objc var scriptGuides: [WTScriptGuide] { guides() }
    @objc(insertInScriptGuides:) func insertInScriptGuides(_ guide: WTScriptGuide) { insertGuide(guide) }
    @objc(insertObject:inScriptGuidesAtIndex:) func insertInScriptGuides(_ guide: WTScriptGuide, at index: Int) { insertGuide(guide) }
    @objc(removeObjectFromScriptGuidesAtIndex:) func removeFromScriptGuides(at index: Int) { removeGuide(at: index) }
}

extension WTScriptMasterPage {
    @objc var scriptGuides: [WTScriptGuide] { guides() }
    @objc(insertInScriptGuides:) func insertInScriptGuides(_ guide: WTScriptGuide) { insertGuide(guide) }
    @objc(insertObject:inScriptGuidesAtIndex:) func insertInScriptGuides(_ guide: WTScriptGuide, at index: Int) { insertGuide(guide) }
    @objc(removeObjectFromScriptGuidesAtIndex:) func removeFromScriptGuides(at index: Int) { removeGuide(at: index) }
}
