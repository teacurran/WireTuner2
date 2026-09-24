import Foundation
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

// Text file import (TYPE-008; type/importing-text.adoc): WTInterchange reads the file into the
// neutral story the RTF export writes from; `TextAttributeMapping` is the one table between that
// story and the document's marks and paragraph registers, read both ways (import here, and
// `story(_:)` for export); `ImportText` writes an import as one change.

/// The mapping between the RTF story's attributes (`ExportTextAttributes`, `ExportParagraphStyle`)
/// and `TextMarkValue`s and `ParagraphProps` (importing-text.adoc, "Client").  The mapped set:
/// font family and face (bold and italic), size, colour, underline and strikethrough (as text
/// effects, underline winning), superscript and subscript (as a baseline shift plus 58% of the
/// size), baseline shift, horizontal scale, tracking (as range kerning), small caps, language,
/// line spacing (as leading), alignment, indents, paragraph spacing, tab stops with alignment and
/// leader, keep-with-next, and the style names.
public enum TextAttributeMapping {
    /// A superscript's or subscript's size, fraction of the type size.
    public static let scriptScale = 0.58
    /// A superscript's rise and a subscript's drop, fraction of the type size.
    public static let superscriptRise = 0.33
    public static let subscriptDrop = 0.14

    // MARK: Import

    /// The marks of an imported run (its character style excepted, which is a node): size and
    /// family always, the rest when not the default; `lineSpacing` is its paragraph's (leading).
    public static func marks(_ a: ExportTextAttributes, lineSpacing: ExportParagraphStyle.LineSpacing = .auto) -> [Wiretuner_Doc_V1_TextMarkValue] {
        var values: [Wiretuner_Doc_V1_TextMarkValue] = []
        func add(_ build: (inout Wiretuner_Doc_V1_TextMarkValue) -> Void) {
            var value = Wiretuner_Doc_V1_TextMarkValue()
            build(&value)
            values.append(value)
        }
        add { $0.fontFamily = a.fontFamily }
        if let face = face(a) { add { $0.fontStyle = face } }
        var size = a.size
        var shift = a.baselineShift
        switch a.script {
        case .superscript:
            shift += a.size * superscriptRise
            size *= scriptScale
        case .subscript:
            shift -= a.size * subscriptDrop
            size *= scriptScale
        case .none: break
        }
        if size > 0 && size <= 10_000 { add { $0.size = (size * 100).rounded() / 100 } }
        if shift != 0 { add { $0.baselineShift = (shift * 100).rounded() / 100 } }
        if a.color != .black { add { $0.fill = ColorResolver.inline(a.color) } }
        if a.underline {
            add { $0.effect.underline = Wiretuner_Doc_V1_TextLineEffect() }
        } else if a.strikethrough {
            add { $0.effect.strikethrough = Wiretuner_Doc_V1_TextLineEffect() }
        }
        if a.horizontalScale != 1, a.horizontalScale > 0 { add { $0.horizontalScale = (a.horizontalScale * 10_000).rounded() / 100 } }
        if a.tracking != 0 { add { $0.rangeKerning = a.tracking / 10 } }
        if a.smallCaps { add { $0.case = .smallCaps } }
        if let language = a.language, !language.isEmpty { add { $0.language = language } }
        switch lineSpacing {
        case .auto: break
        case .multiple(let factor): add { $0.leading = .with { $0.mode = .percent; $0.value = (factor * 120 * 100).rounded() / 100 } }
        case .exactly(let points): add { $0.leading = .with { $0.mode = .fixed; $0.value = points } }
        }
        return values
    }

    /// The face a run names: its own, else "Bold Italic", "Bold" or "Italic"; nil for regular.
    static func face(_ a: ExportTextAttributes) -> String? {
        if let face = a.fontFace, !face.isEmpty { return face == "Regular" && !a.bold && !a.italic ? nil : face }
        switch (a.bold, a.italic) {
        case (true, true): return "Bold Italic"
        case (true, false): return "Bold"
        case (false, true): return "Italic"
        default: return nil
        }
    }

    /// The registers an imported paragraph writes (tab stops included, as `tabs`), and the fields.
    public static func paragraph(_ s: ExportParagraphStyle) -> (props: Wiretuner_Doc_V1_ParagraphProps, fields: [UInt32]) {
        var props = Wiretuner_Doc_V1_ParagraphProps()
        switch s.alignment {
        case .left: break
        case .center: props.alignment = .center
        case .right: props.alignment = .right
        case .justified: props.alignment = .justified
        }
        props.leftIndent = s.leftIndent
        props.rightIndent = s.rightIndent
        props.firstLineIndent = s.firstLineIndent
        props.spaceAbove = s.spaceBefore
        props.spaceBelow = s.spaceAfter
        props.keepWithNext = s.keepWithNext
        props.tabs = s.tabStops.map { stop in
            var tab = Wiretuner_Doc_V1_TabStop()
            tab.position = stop.position
            switch stop.alignment {
            case .left: tab.kind = .left
            case .center: tab.kind = .center
            case .right: tab.kind = .right
            case .decimal: tab.kind = .decimal
            }
            switch stop.leader {
            case .none: break
            case .dots: tab.leader = "."
            case .hyphens: tab.leader = "-"
            case .underline: tab.leader = "_"
            }
            return tab
        }
        return (props, TextStyleAttributes.setFields(props))
    }

    // MARK: Export

    /// The RTF attributes of resolved mark values (`values` in precedence order, later winning).
    public static func attributes(_ values: [Wiretuner_Doc_V1_TextMarkValue], colors: ColorResolver? = nil) -> ExportTextAttributes {
        var a = ExportTextAttributes()
        for value in values {
            switch value.value {
            case .fontFamily(let family)?: if !family.isEmpty { a.fontFamily = family }
            case .fontStyle(let face)?:
                a.fontFace = face.isEmpty ? nil : face
                a.bold = face.localizedCaseInsensitiveContains("bold")
                a.italic = face.localizedCaseInsensitiveContains("italic") || face.localizedCaseInsensitiveContains("oblique")
            case .size(let size)?: if size > 0 { a.size = size }
            case .baselineShift(let shift)?: a.baselineShift = shift
            case .fill(let ref)?: a.color = colors?.color(ref) ?? Appearances.color(ref) ?? .black
            case .effect(let effect)?:
                a.underline = false
                a.strikethrough = false
                switch effect.effect {
                case .underline?: a.underline = true
                case .strikethrough?: a.strikethrough = true
                default: break
                }
            case .horizontalScale(let scale)?: if scale > 0 { a.horizontalScale = scale / 100 }
            case .rangeKerning(let tracking)?: a.tracking = tracking * 10
            case .case(let style)?: a.smallCaps = style == .smallCaps
            case .language(let language)?: a.language = language.isEmpty ? nil : language
            default: break
            }
        }
        return a
    }

    /// The RTF paragraph attributes of a paragraph's resolved registers and its first run's leading.
    public static func style(_ p: Wiretuner_Doc_V1_ParagraphProps, leading: Wiretuner_Doc_V1_Leading? = nil) -> ExportParagraphStyle {
        var s = ExportParagraphStyle()
        switch p.alignment {
        case .center: s.alignment = .center
        case .right: s.alignment = .right
        case .justified: s.alignment = .justified
        default: s.alignment = .left
        }
        s.leftIndent = p.leftIndent
        s.rightIndent = p.rightIndent
        s.firstLineIndent = p.firstLineIndent
        s.spaceBefore = p.spaceAbove
        s.spaceAfter = p.spaceBelow
        s.keepWithNext = p.keepWithNext
        s.tabStops = p.tabs.map { tab in
            let alignment: ExportTabStop.Alignment = switch tab.kind {
            case .center: .center
            case .right: .right
            case .decimal: .decimal
            default: .left
            }
            let leader: ExportTabStop.Leader = switch tab.leader {
            case ".": .dots
            case "-": .hyphens
            case "_": .underline
            default: .none
            }
            return ExportTabStop(position: tab.position, alignment: alignment, leader: leader)
        }
        if let leading {
            switch leading.mode {
            case .percent: s.lineSpacing = .multiple(leading.value / 120)
            case .fixed: s.lineSpacing = .exactly(leading.value)
            default: break
            }
        }
        return s
    }

    /// The story of a text node for RTF and plain-text export: its paragraphs with resolved
    /// attributes (styles resolved when `styles` is given), their style names, and inline graphics
    /// as U+FFFC runs without a picture.
    public static func story(_ text: TextNode, styles: TextStyleResolver? = nil, colors: ColorResolver? = nil) -> ExportStory {
        let scalars = Array(text.string.unicodeScalars)
        let runs = text.runs
        return ExportStory(paragraphs: text.paragraphs.map { paragraph in
            let content = paragraph.range.lowerBound..<(paragraph.terminator == nil ? paragraph.range.upperBound : paragraph.range.upperBound - 1)
            var exported: [ExportTextRun] = []
            var leading: Wiretuner_Doc_V1_Leading?
            for run in runs {
                let range = run.range.clamped(to: content)
                guard !range.isEmpty else { continue }
                let values = styles?.characterValues(run.values, paragraph: paragraph.props) ?? run.values
                if leading == nil {
                    leading = values.compactMap { if case .leading(let value)? = $0.value { value } else { nil } }.last
                }
                var attributes = attributes(values, colors: colors)
                if let styles, let ref = run.values.compactMap({ if case .style(let ref)? = $0.value { ref } else { nil } }).last,
                   let id = styles.reference(ref, kind: .character)?.style {
                    attributes.styleName = styles.style(id)?.name
                }
                var string = ""
                string.unicodeScalars.append(contentsOf: scalars[range])
                exported.append(ExportTextRun(string, attributes: attributes))
            }
            let props = styles?.paragraph(paragraph.props) ?? paragraph.props
            var style = style(props, leading: leading)
            if let styles, let id = styles.paragraphStyle(paragraph.props).style, id != styles.normalText {
                style.styleName = styles.style(id)?.name
            }
            return ExportParagraph(exported, style: style)
        })
    }
}

/// menu:File[Import…] of a text file placed with a click (an auto-expanding block at the point) or
/// a drag (a fixed-size block of the rectangle), and a Finder drop (a click at the drop point): one
/// change, "Import text".  The characters go in 64 KiB `TextInsert`s; each attribute is one mark
/// per stretch of consecutive runs holding the same value; each paragraph's registers are written
/// on its terminating newline (the last on `tail_paragraph`) with its tab stops; paragraph and
/// character style names the document lacks become text styles -- with no settings, so the
/// imported registers and marks alone decide the look; an RTFD's pictures become image children drawn as
/// inline graphics (their bytes, `blobs`, are the app's to store); the import summary is the
/// block's note.  Plain text takes `defaults` (the default text attributes) over all of it.
public struct ImportText: Command {
    public var file: ImportedTextFile
    public var frame: CreateTextBlock.Frame
    public var defaults: [Wiretuner_Doc_V1_TextMarkValue]
    public var layer: OpID?
    public var label: String { "Import text" }

    /// The largest `TextInsert` the server takes, in UTF-8 bytes.
    static let chunkBytes = 65_536

    public init(_ file: ImportedTextFile, frame: CreateTextBlock.Frame, defaults: [Wiretuner_Doc_V1_TextMarkValue] = [], layer: OpID? = nil) {
        self.file = file
        self.frame = frame
        self.defaults = defaults
        self.layer = layer
    }

    /// The pictures' bytes, for the document's blob store.
    public var blobs: [ImportedBlob] {
        file.pictures.keys.sorted().map { ImportedBlob(data: file.pictures[$0]!.data, uti: file.pictures[$0]!.uti) }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !file.paragraphs.isEmpty else { throw TextEditError.invalidValue("file") }
        // The text and each run's span of scalars.
        var scalars: [Unicode.Scalar] = []
        var spans: [(range: Range<Int>, values: [Wiretuner_Doc_V1_TextMarkValue], graphic: CGSize?)] = []
        var newlines: [Int] = []
        let resolver = TextStyleResolver(state)
        var refs: [String: Wiretuner_Doc_V1_NodeRef] = [:]
        var created: [(name: String, kind: TextStyleKind, attrs: Wiretuner_Doc_V1_TextStyleAttrs)] = []
        func style(_ name: String, kind: TextStyleKind, attrs: Wiretuner_Doc_V1_TextStyleAttrs) -> String {
            let key = "\(kind == .paragraph ? "p" : "c"):\(name)"
            if refs[key] == nil, !created.contains(where: { $0.name == name && $0.kind == kind }) {
                if let existing = resolver.styles(kind).first(where: { $0.name == name }) {
                    refs[key] = resolver.ref(existing.id)
                } else {
                    created.append((name, kind, attrs))
                }
            }
            return key
        }
        var paragraphStyleKeys: [String?] = []
        var characterStyleKeys: [Int: String] = [:]
        for (index, paragraph) in file.paragraphs.enumerated() {
            if index > 0 {
                newlines.append(scalars.count)
                scalars.append("\n")
            }
            paragraphStyleKeys.append(paragraph.style.styleName.map { name in style(name, kind: .paragraph, attrs: .init()) })
            for run in paragraph.runs {
                var text = Array(run.text.unicodeScalars)
                if run.attributes.allCaps { text = Array(run.text.uppercased().unicodeScalars) }
                guard !text.isEmpty else { continue }
                let values = file.plain ? defaults : TextAttributeMapping.marks(run.attributes, lineSpacing: paragraph.style.lineSpacing)
                if let name = run.attributes.styleName, !file.plain {
                    characterStyleKeys[spans.count] = style(name, kind: .character, attrs: .init())
                }
                let graphic = run.text == "\u{FFFC}" && file.pictures[scalars.count] != nil ? run.graphicSize : nil
                spans.append((scalars.count..<scalars.count + text.count, values, graphic))
                scalars += text
            }
        }
        // The block.
        var props = Wiretuner_Doc_V1_NodeProps()
        let origin: Point
        switch frame {
        case .point(let point):
            origin = point
            props.text.block.autoWidth = true
            props.text.block.autoHeight = true
        case .area(let rect):
            guard rect.width > 0, rect.height > 0 else { throw TextEditError.invalidValue("frame") }
            origin = Point(x: rect.minX, y: rect.minY)
            props.text.block.width = rect.width
            props.text.block.height = rect.height
        }
        if origin != .zero { props.text.common.transform = PathEditing.proto(AffineTransform.translation(x: origin.x, y: origin.y)) }
        if !file.notes.isEmpty { props.text.common.note = String(file.notes.joined(separator: "\n").prefix(8192)) }
        let layer = try PathEditing.ensureLayer(&builder, state: state, preferred: self.layer)
        let node = builder.append(Ops.create(parent: layer, position: try PathEditing.topPosition(in: layer, state: state), props: props))
        // The styles it names that the document lacks.
        if !created.isEmpty {
            let top = state.store.children(TextStyleFields.collection).last.flatMap { state.store.placement($0)?.position }
            let keys = try PathEditing.keys(between: top, and: nil, count: created.count)
            for (entry, key) in zip(created, keys) {
                var style = Wiretuner_Doc_V1_NodeProps()
                style.style.common.name = entry.name
                style.style.kind = entry.kind.stored
                var attrs = entry.attrs
                let tabs = attrs.paragraph.tabs
                attrs.paragraph.tabs = []
                style.style.text = attrs
                let id = builder.append(Ops.create(parent: TextStyleFields.collection, position: key, props: style))
                try TextStyleEditing.insertTabs(tabs, into: id, builder: &builder)
                // A new style's settings are empty: so is the cache of what it resolves to.
                refs["\(entry.kind == .paragraph ? "p" : "c"):\(entry.name)"] = .with { $0.id = id.proto }
            }
        }
        func ref(_ key: String) -> Wiretuner_Doc_V1_NodeRef { refs[key]! }
        guard !scalars.isEmpty else { return }
        // The characters, in chunks.
        var ids: [OpID] = []
        var left = OpID.zero
        for chunk in Self.chunks(scalars) {
            var string = String.UnicodeScalarView()
            string.append(contentsOf: chunk)
            let first = builder.append(Ops.textInsert(node, TextFields.text, String(string), left: left))
            ids += (0..<chunk.count).map { OpID(counter: first.counter + UInt64($0), replica: first.replica) }
            left = ids[ids.count - 1]
        }
        // Paragraph registers.
        for (index, paragraph) in file.paragraphs.enumerated() {
            var (props, fields) = file.plain ? (Wiretuner_Doc_V1_ParagraphProps(), []) : TextAttributeMapping.paragraph(paragraph.style)
            if let key = paragraphStyleKeys[index] {
                props.style = ref(key)
                fields.append(17)
            }
            let newline = index < newlines.count ? ids[newlines[index]] : nil
            let base = newline.map(TextFields.paragraph) ?? TextFields.tailParagraph
            let tabs = props.tabs
            props.tabs = []
            let registers = fields.filter { $0 != TextFields.tabsField }
            if !registers.isEmpty {
                builder.append(Ops.set(node, registers.map { base.child($0) }, values: TextEditing.paragraphValues(props, newline: newline != nil)))
            }
            if !tabs.isEmpty {
                let keys = try PathEditing.keys(between: nil, and: nil, count: tabs.count)
                builder.append(Ops.elementInsert(node, base.child(TextFields.tabsField), positions: keys,
                                                 values: TextEditing.paragraphValues(.with { $0.tabs = tabs }, newline: newline != nil)))
            }
        }
        // Inline pictures: an image child each, named by its placeholder's mark.
        for (index, span) in spans.enumerated() {
            guard let size = span.graphic, let picture = file.pictures[span.range.lowerBound],
                  let decoded = try? ImageImporter().decode(picture.data, name: "Picture") else { continue }
            var image = decoded.image(name: "Picture")
            // The picture drawn at the size the document gave it.
            let natural = Size(width: Double(decoded.pixels.width) / decoded.dpiX * 72, height: Double(decoded.pixels.height) / decoded.dpiY * 72)
            if size.width > 0, size.height > 0, natural.width > 0, natural.height > 0 {
                image.transform = AffineTransform.scale(x: Double(size.width) / natural.width, y: Double(size.height) / natural.height)
            }
            let child = builder.append(Ops.create(parent: node, position: try PathEditing.keys(between: nil, and: nil, count: 1)[0],
                                                  props: ImportMapping.image(image, source: nil, placement: .identity)))
            spans[index].values = [InlineGraphics.mark(child)]
        }
        // Character style marks.
        for (index, key) in characterStyleKeys {
            spans[index].values.append(.with { $0.style = ref(key) })
        }
        // One mark per attribute per stretch of runs holding the same value.
        var byKey: [String: [(range: Range<Int>, value: Wiretuner_Doc_V1_TextMarkValue)]] = [:]
        for span in spans {
            for value in span.values {
                let key = TextStyleAttributes.key(value)
                if var stretches = byKey[key], let last = stretches.last, last.value == value, last.range.upperBound == span.range.lowerBound
                    || (last.range.upperBound + 1 == span.range.lowerBound && newlines.contains(last.range.upperBound)) {
                    stretches[stretches.count - 1].range = last.range.lowerBound..<span.range.upperBound
                    byKey[key] = stretches
                } else {
                    byKey[key, default: []].append((span.range, value))
                }
            }
        }
        for key in byKey.keys.sorted() {
            for stretch in byKey[key]! {
                let next = stretch.range.upperBound < ids.count ? ids[stretch.range.upperBound] : .zero
                builder.append(TextEditing.mark(node, stretch.value, first: ids[stretch.range.lowerBound], last: ids[stretch.range.upperBound - 1], next: next))
            }
        }
    }

    /// `scalars` in runs of at most `chunkBytes` UTF-8 bytes.
    static func chunks(_ scalars: [Unicode.Scalar]) -> [ArraySlice<Unicode.Scalar>] {
        var result: [ArraySlice<Unicode.Scalar>] = []
        var start = 0
        var bytes = 0
        for (index, scalar) in scalars.enumerated() {
            let size = UTF8.width(scalar)
            if bytes + size > chunkBytes {
                result.append(scalars[start..<index])
                start = index
                bytes = 0
            }
            bytes += size
        }
        result.append(scalars[start...])
        return result
    }
}
