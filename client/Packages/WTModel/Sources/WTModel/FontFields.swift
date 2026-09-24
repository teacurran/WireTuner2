import WTCRDT
import WTProto

// FONT-002: register paths of the typeface fields (typeface-documents.adoc, "Data model"):
// `SettingsProps.document_kind` (20) and `SettingsProps.font` (21, `FontProps`) on the settings
// node 0:1, and the `glyph` node kind (`NodeProps.glyph` = 220) under the well-known glyphs
// collection 0:11.

extension WellKnown {
    /// The glyphs collection (0:11): children are `glyph` nodes in custom grid order.
    public static let glyphs = OpID.wellKnown(11)
}

extension OpID {
    /// The id of a sequence element as `EngineState.props` reads it (always set there).
    init(sequenceElement id: Wiretuner_Doc_V1_ElementId) {
        self.init(counter: id.counter, replica: id.replica)
    }
}

/// Register paths of `GlyphProps` (`NodeProps.glyph` = 220).
public enum GlyphFields {
    public static let kind: UInt32 = 220
    public static let note = RegisterPath([220, 1, 2])
    public static let name = RegisterPath([220, 2])
    public static let codepoints = RegisterPath([220, 3])
    public static let advanceWidth = RegisterPath([220, 4])
    public static let glyphKind = RegisterPath([220, 5])
    public static let components = RegisterPath([220, 6])
    public static let anchors = RegisterPath([220, 7])
    public static let skipExport = RegisterPath([220, 8])
    public static let guides = RegisterPath([220, 9])
    public static let markColor = RegisterPath([220, 10])

    public static func component(_ id: OpID) -> RegisterPath { components.element(id) }
    public static func componentTransform(_ id: OpID) -> RegisterPath { component(id).child(3) }
    public static func anchor(_ id: OpID) -> RegisterPath { anchors.element(id) }
    public static func anchorName(_ id: OpID) -> RegisterPath { anchor(id).child(2) }
    public static func anchorPosition(_ id: OpID) -> RegisterPath { anchor(id).child(3) }
    public static func anchorRole(_ id: OpID) -> RegisterPath { anchor(id).child(4) }
    public static func guide(_ id: OpID) -> RegisterPath { guides.element(id) }
    public static func guidePosition(_ id: OpID) -> RegisterPath { guide(id).child(3) }

    /// A sparse `NodeProps` holding the glyph values `build` sets.
    public static func values(_ build: (inout Wiretuner_Doc_V1_GlyphProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        build(&props.glyph)
        return props
    }

    /// The SET values of `codepoints` holding `scalars`.
    static func codepointValues(_ scalars: [UInt32]) -> Wiretuner_Doc_V1_NodeProps {
        values { $0.codepoints = scalars }
    }
}

/// Register paths of the typeface fields of `SettingsProps` (`document_kind` = 20, `font` = 21).
public enum FontFields {
    public static let documentKind = RegisterPath([2, 20])
    public static let font = RegisterPath([2, 21])

    /// `FontNames` field `number`.
    public static func name(_ number: UInt32) -> RegisterPath { RegisterPath([2, 21, 1, number]) }
    /// `FontMetrics` field `number`.
    public static func metric(_ number: UInt32) -> RegisterPath { RegisterPath([2, 21, 2, number]) }
    /// `Os2Props` field `number`.
    public static func os2(_ number: UInt32) -> RegisterPath { RegisterPath([2, 21, 3, number]) }
    /// `MetricGuideSettings` field `number`.
    public static func guides(_ number: UInt32) -> RegisterPath { RegisterPath([2, 21, 4, number]) }
    public static let extraLines = RegisterPath([2, 21, 4, 12])
    public static func extraLine(_ id: OpID) -> RegisterPath { extraLines.element(id) }
    public static func extraLineY(_ id: OpID) -> RegisterPath { extraLine(id).child(3) }
    public static let pairs = RegisterPath([2, 21, 5])
    public static let classes = RegisterPath([2, 21, 6])
    public static let classKerns = RegisterPath([2, 21, 7])
    public static let features = RegisterPath([2, 21, 8])
    public static let omitGeneratedKern = RegisterPath([2, 21, 9])
    public static let omitGeneratedMark = RegisterPath([2, 21, 10])
    public static let omitGeneratedLiga = RegisterPath([2, 21, 11])

    public static func pair(_ id: OpID) -> RegisterPath { pairs.element(id) }
    public static func pairValue(_ id: OpID) -> RegisterPath { pair(id).child(4) }
    public static func kernClass(_ id: OpID) -> RegisterPath { classes.element(id) }
    public static func kernClassName(_ id: OpID) -> RegisterPath { kernClass(id).child(2) }
    public static func kernClassMembers(_ id: OpID) -> RegisterPath { kernClass(id).child(4) }
    public static func kernClassMember(_ kernClass: OpID, _ member: OpID) -> RegisterPath { kernClassMembers(kernClass).element(member) }
    public static func classKern(_ id: OpID) -> RegisterPath { classKerns.element(id) }
    public static func classKernValue(_ id: OpID) -> RegisterPath { classKern(id).child(4) }

    /// A sparse `NodeProps` holding the settings values `build` sets.
    public static func values(_ build: (inout Wiretuner_Doc_V1_SettingsProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        build(&props.settings)
        return props
    }

    /// A sparse `NodeProps` holding the `FontProps` values `build` sets.
    public static func fontValues(_ build: (inout Wiretuner_Doc_V1_FontProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        values { build(&$0.font) }
    }
}
