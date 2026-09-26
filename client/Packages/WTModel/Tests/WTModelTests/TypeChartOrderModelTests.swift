import CoreText
import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// The model halves of TYPE-012 (smart quotes, special characters), TYPE-027 (spacing merge),
/// TYPE-031 (text attribute sets), TYPE-046 (font offers, feature merge), LIB-021 (clearing an
/// override), DRAW-034 (pictographs, ungroup) and OBJ-041 (reading order).
@Suite struct TypeChartOrderModelTests {
    // MARK: Smart quotes and special characters (TYPE-012)

    @Test func smartQuotesOpenAfterSpaceAndBracketsAndCloseAfterLettersAndDigits() {
        let english = SmartQuotes.set("english")
        #expect(english.replacement(for: "\"", after: nil) == "\u{201C}")
        #expect(english.replacement(for: "\"", after: " ") == "\u{201C}")
        #expect(english.replacement(for: "\"", after: "(") == "\u{201C}")
        #expect(english.replacement(for: "\"", after: "a") == "\u{201D}")
        #expect(english.replacement(for: "\"", after: "7") == "\u{201D}")
        #expect(english.replacement(for: "'", after: "n") == "\u{2019}", "an apostrophe")
        #expect(english.replacement(for: "'", after: "\n") == "\u{2018}")
        #expect(english.replacement(for: "'", after: "\u{201C}") == "\u{2018}", "inside an opening double")
        #expect(english.replacement(for: "x", after: nil) == "x")
        #expect(SmartQuotes.set("german").replacement(for: "\"", after: nil) == "\u{201E}")
        #expect(SmartQuotes.set("swedish").replacement(for: "\"", after: "\u{201D}") == "\u{201D}")
        #expect(SmartQuotes.set("guillemets").replacement(for: "'", after: "a") == "\u{203A}")
        #expect(SmartQuotes.set("guillemets_reversed").openDouble == "\u{00BB}")
        #expect(SmartQuotes.set("corner").closeSingle == "\u{300F}")
        #expect(SmartQuotes.set("unknown") == english && SmartQuotes.sets.count == 6)
    }

    @Test func eachSpecialCharacterHasItsCodePointTitleAndInvisibleMark() {
        let points: [SpecialCharacter: UInt32] = [.endOfColumn: 0x0C, .endOfLine: 0x2028, .nonBreakingSpace: 0xA0, .emSpace: 0x2003, .enSpace: 0x2002,
                                                  .thinSpace: 0x2009, .emDash: 0x2014, .enDash: 0x2013, .discretionaryHyphen: 0xAD]
        for character in SpecialCharacter.allCases {
            #expect(character.character.unicodeScalars.first?.value == points[character])
            #expect(!character.title.isEmpty)
        }
        for scalar: Unicode.Scalar in [" ", "\u{00A0}", "\u{2003}", "\t", "\n", "\u{2028}", "\u{000C}", "\u{00AD}"] {
            #expect(SpecialCharacter.invisibleMark(for: scalar) != nil)
        }
        #expect(SpecialCharacter.invisibleMark(for: "a") == nil)
    }

    @Test func anEndOfColumnConcurrentWithTypingInTheNextColumnKeepsBoth() throws {
        var pair = Pair()
        let node = try TextFixture.block(&pair.a, "left right")
        pair.sync()
        try pair.a.perform(InsertText(node: node, text: String(SpecialCharacter.endOfColumn.character), at: TextFixture.at(pair.a, node, 5)))
        try pair.b.perform(InsertText(node: node, text: "most", at: TextFixture.at(pair.b, node, 10), typing: true))
        pair.sync()
        #expect(TextFixture.text(pair.a, node).string == "left \u{000C}rightmost")
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }

    // MARK: Spacing (TYPE-027)

    @Test func concurrentWordSpacingTriplesConvergeToOneWholeTriple() throws {
        var pair = Pair()
        let node = try TextFixture.block(&pair.a, "Justified words")
        pair.sync()
        let a = try #require(try pair.a.perform(SetParagraph(node: node, from: .start, to: .end, props: .with { $0.wordSpacing = .with { $0.min = 70; $0.opt = 90; $0.max = 120 } }, fields: [[15]])))
        let b = try #require(try pair.b.perform(SetParagraph(node: node, from: .start, to: .end, props: .with { $0.wordSpacing = .with { $0.min = 85; $0.opt = 110; $0.max = 160 } }, fields: [[15]])))
        pair.sync()
        let spacing = TextFixture.text(pair.a, node).paragraphs[0].props.wordSpacing
        let winner = PageFixture.later(a, b) ? (70.0, 90.0, 120.0) : (85.0, 110.0, 160.0)
        #expect((spacing.min, spacing.opt, spacing.max) == winner, "never a mix of the two")
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }

    // MARK: Text attribute sets (TYPE-031)

    /// Every attribute of the copying-type table set on a source block.
    static func source(_ a: inout Replica) throws -> OpID {
        let paragraph = Wiretuner_Doc_V1_ParagraphProps.with {
            $0.alignment = .center
            $0.raggedWidth = 80
            $0.flushZone = 20
            $0.spaceAbove = 4
            $0.spaceBelow = 5
            $0.leftIndent = 6
            $0.rightIndent = 7
            $0.firstLineIndent = 8
            $0.tabs = [.with { $0.position = 36; $0.kind = .right; $0.leader = "." }]
            $0.hyphenation = .with { $0.enabled = true; $0.language = "de"; $0.consecutive = 2 }
            $0.rule = .with { $0.mode = .paragraph; $0.widthPercent = 50 }
            $0.hangPunctuation = true
            $0.keepLines = 2
            $0.keepWithNext = true
            $0.wordSpacing = .with { $0.min = 80; $0.opt = 95; $0.max = 130 }
            $0.letterSpacing = .with { $0.min = -2; $0.opt = 0; $0.max = 4 }
        }
        let node = try TextFixture.block(&a, "Source", paragraph: paragraph)
        try a.perform(AddTabStop(node: node, from: .start, to: .end, stop: .with { $0.position = 36; $0.kind = .right; $0.leader = "." }))
        try a.perform(AddTabStop(node: node, from: .start, to: .end, stop: .with { $0.position = 18 }))
        let values: [Wiretuner_Doc_V1_TextMarkValue] = [
            TextFixture.family("Helvetica"), TextFixture.mark { $0.fontStyle = "Bold" }, TextFixture.size(18),
            TextFixture.mark { $0.leading = .with { $0.mode = .fixed; $0.value = 22 } }, TextFixture.mark { $0.rangeKerning = 5 },
            TextFixture.mark { $0.baselineShift = 2 }, TextFixture.mark { $0.horizontalScale = 90 },
            TextFixture.mark { $0.effect = .with { $0.underline = .init() } }, TextFixture.mark { $0.fill = Appearances.inline(red: 1, green: 0, blue: 0) },
            TextFixture.mark { $0.stroke = TextColor.defaultStroke }, TextFixture.mark { $0.case = .smallCaps }, TextFixture.mark { $0.language = "fr" },
        ]
        for value in values { try a.perform(ApplyMark(node: node, from: .start, to: .end, value: value)) }
        try a.perform(AddTextBlockAppearance.fill(node))
        try a.perform(AddTextBlockAppearance.stroke(node))
        return node
    }

    @Test func capturingFromARangeAndPastingOntoABlockReproducesEveryAttribute() throws {
        var a = Replica(0xA)
        _ = try LayerFixture.layers(["Art"], on: &a)
        let source = try Self.source(&a)
        let target = try TextFixture.block(&a, "Target text", at: Point(x: 0, y: 100))
        try a.perform(ApplyMark(node: target, from: .start, to: .end, value: TextFixture.mark { $0.overprint = true }))
        try a.perform(ApplyMark(node: target, from: .start, to: TextFixture.at(a, target, 3), value: TextFixture.mark { $0.overprint = false }))
        try a.perform(ApplyMark(node: target, from: .start, to: .end, value: TextFixture.feature("ss01", .on)))
        try a.perform(AddTabStop(node: target, from: .start, to: .end, stop: .with { $0.position = 100 }))
        let set = TextAttributeSet.capture(from: TextFixture.text(a, source), range: 1..<3, in: a.state)
        #expect(set.stack == nil && set.character.count == 12 && set.paragraph?.alignment == .center)
        let change = try #require(try a.perform(PasteTextAttributes(set, to: [TextAttributeTarget(node: target)])))
        #expect(change.label == "Paste attributes")
        let text = TextFixture.text(a, target)
        let pasted = Set(text.values(at: 4).filter(TextAttributeSet.travels).map { String(describing: $0) })
        #expect(pasted == Set(set.character.map { String(describing: $0) }), "the overprint mark is cleared, the rest reproduced")
        var expected = set.paragraph!
        expected.tabs = []
        var got = text.paragraphs[0].props
        let stops = TextTabs.stops(text.paragraphs[0]).map(\.stop)
        got.tabs = []
        #expect(got == expected)
        #expect(stops.count == 2 && stops[1].position == 36 && stops[1].kind == .right && stops[1].leader == ".", "tabs replaced")
        // A block source carries its block appearance; the clipboard round trip keeps all three.
        let block = TextAttributeSet.capture(from: TextFixture.text(a, source), block: true, in: a.state)
        #expect(block.stack?.count == 2)
        let decoded = try #require(TextAttributeSet(block.clipboard(sourceDocument: "d")))
        #expect(decoded == block)
        #expect(TextAttributeSet(ClipboardPayload(nodes: [NodeTree(props: .init())])) == nil)
        #expect(TextAttributeSet(AttributePayload(stack: nil, textAttributes: []).clipboard())?.paragraph == nil)
        // Filters (the Eyedropper's Shift and Cmd).
        #expect(block.filtered(character: true, paragraph: false).paragraph == nil)
        #expect(block.filtered(character: false, paragraph: true).character.isEmpty)
        // An empty block source has no character attributes; pasting paragraphs only writes them.
        let empty = try TextFixture.block(&a, "", at: Point(x: 0, y: 200))
        let bare = TextAttributeSet.capture(from: TextFixture.text(a, empty), in: a.state)
        #expect(bare.character.isEmpty)
        try a.perform(PasteTextAttributes(bare, to: [TextAttributeTarget(node: target, from: .start, to: TextFixture.at(a, target, 1))]))
        #expect(TextFixture.text(a, target).paragraphs[0].props.alignment == .unspecified)
        // A caret target takes no character attributes.
        try a.perform(PasteTextAttributes(set, to: [TextAttributeTarget(node: target, from: TextFixture.at(a, target, 2), to: TextFixture.at(a, target, 2))]))
    }

    @Test func pastingOntoAPathAppliesOnlyTheBlockAppearance() throws {
        var a = Replica(0xA)
        _ = try LayerFixture.layers(["Art"], on: &a)
        let source = try Self.source(&a)
        let rect = try PageFixture.rect(&a, at: Point(x: 200, y: 200))
        let set = TextAttributeSet.capture(from: TextFixture.text(a, source), block: true, in: a.state)
        let stack = try #require(set.stackPayload)
        try a.perform(PasteAttributes(stack, to: [rect], in: a.state))
        let appearance = a.state.props(rect).rect.appearance
        #expect(appearance.fills.count == 1 && appearance.strokes.count == 1, "the block's fill and stroke, nothing typographic")
        #expect(TextAttributeSet(character: [], paragraph: nil).stackPayload == nil)
    }

    @Test func aPasteOntoAParagraphWhileARemoteReplicaAddsATabConverges() throws {
        var pair = Pair()
        _ = try LayerFixture.layers(["Art"], on: &pair.a)
        let source = try Self.source(&pair.a)
        let target = try TextFixture.block(&pair.a, "Target", at: Point(x: 0, y: 100))
        pair.sync()
        let set = TextAttributeSet.capture(from: TextFixture.text(pair.a, source), in: pair.a.state)
        try pair.a.perform(PasteTextAttributes(set, to: [TextAttributeTarget(node: target)]))
        try pair.b.perform(AddTabStop(node: target, from: .start, to: .end, stop: .with { $0.position = 144 }))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let positions = TextTabs.stops(TextFixture.text(pair.a, target).paragraphs[0]).map(\.stop.position)
        #expect(positions == [18, 36, 144], "the remote stop sits beside the pasted copies")
    }

    // MARK: Font offers (TYPE-046)

    @Test func aVariableFaceOffersItsAxesAndNamedInstances() throws {
        let font = try #require(FontOffers.font(family: "STIX Two Text", style: "Regular"))
        let axes = FontOffers.axes(of: font)
        let weight = try #require(axes.first { $0.tag == "wght" })
        #expect(weight.minimum == 400 && weight.maximum == 700 && weight.defaultValue == 400 && !weight.name.isEmpty)
        #expect(weight.clamped(900) == 700 && weight.clamped(100) == 400)
        let instances = FontOffers.instances(family: "STIX Two Text")
        #expect(instances.contains { $0.style == "Bold" && $0.axes["wght"] == 700 })
        #expect(instances.contains { $0.style == "Regular" && $0.axes["wght"] == 400 }, "a face without values stands at the defaults")
        #expect(FontOffers.instances(family: "Helvetica").isEmpty, "a static family has no instances")
        #expect(FontOffers.font(family: "No Such Family Anywhere", style: nil) == nil)
        #expect(FontOffers.tag(0x7767_6874) == "wght" && FontOffers.tag(0xFFFF_FFFF) == "")
        #expect(FontOffers.instances(family: "No Such Family Anywhere").isEmpty)
        #expect(FontOffers.instances(family: "Skia").contains { $0.axes["wdth"] != nil })
        #expect(FontOffers.dictionaries(nil).isEmpty && FontOffers.number([:], kCTFontVariationAxisIdentifierKey) == nil)
    }

    @Test func featuresAreTheOfferedOnesWithStylisticSetNames() throws {
        let mukta = FontOffers.features(family: "Mukta Mahee", style: "Regular")
        #expect(mukta.contains("ss01") && !mukta.contains("swsh"))
        let font = try #require(FontOffers.font(family: "Mukta Mahee", style: "Regular"))
        let names = FontOffers.stylisticSetNames(of: font)
        #expect(names["ss01"] == "Alternate a g")
        #expect(FontOffers.title("ss01", names: names) == "Alternate a g" && FontOffers.title("ss02") == "Stylistic set 2")
        #expect(FontOffers.title("liga") == "Ligatures" && FontOffers.title("xxxx") == "xxxx")
        #expect(FontOffers.features(family: "No Such Family Anywhere", style: nil).isEmpty)
        #expect(FontOffers.featureTags.count == 31)
    }

    @Test func styleFeatureSettingsReadAndWriteByTag() {
        var settings = Wiretuner_Doc_V1_FeatureSettings()
        #expect(settings.state("liga") == nil)
        settings.set("liga", .off)
        settings.set("ss03", .on)
        #expect(settings.state("liga") == .off && settings.state("ss03") == .on)
        settings.set("liga", nil)
        #expect(settings.state("liga") == nil && settings.state("ss03") == .on)
        settings.set("nope", .on)
        #expect(settings.state("nope") == nil)
        #expect(Wiretuner_Doc_V1_FeatureSettings.field("liga") == 1 && Wiretuner_Doc_V1_FeatureSettings.field("ss01") == 21)
        #expect(Wiretuner_Doc_V1_FeatureSettings.field("nope") == nil)
    }

    @Test func oppositeLigatureMarksFromTwoReplicasGoToTheGreaterOpID() throws {
        var pair = Pair()
        let node = try TextFixture.block(&pair.a, "office")
        pair.sync()
        let on = try #require(try pair.a.perform(ApplyMark(node: node, from: .start, to: .end, value: TextFixture.feature("liga", .on))))
        let off = try #require(try pair.b.perform(ApplyMark(node: node, from: .start, to: .end, value: TextFixture.feature("liga", .off))))
        pair.sync()
        let state = TextFixture.text(pair.a, node).values(at: 2).compactMap { value -> Wiretuner_Doc_V1_FeatureState? in
            if case .feature(let feature)? = value.value, feature.tag == "liga" { feature.state } else { nil }
        }.first
        #expect(state == (PageFixture.later(on, off) ? .on : .off))
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }

    // MARK: Clear Override (LIB-021)

    @Test func clearOverrideClearsOnlyThatCategory() throws {
        var a = Replica(0xA)
        _ = try LayerFixture.layers(["Art"], on: &a)
        let rect = try PageFixture.rect(&a, at: .zero)
        try a.perform(CreateGraphicStyle(.selection(rect), applyTo: [rect]))
        #expect(GraphicStyleDefaults.overrides(of: rect, in: a.state).isEmpty)
        try a.perform(AddAppearance.fill([rect]))
        try a.perform(AddAppearance.stroke([rect]))
        let before = GraphicStyleDefaults.overrides(of: rect, in: a.state)
        #expect(before.contains(.fills) && before.contains(.strokes))
        let change = try #require(try a.perform(ClearGraphicStyleOverride([rect], category: .fills)))
        #expect(change.label == "Clear Override")
        let after = GraphicStyleDefaults.overrides(of: rect, in: a.state)
        #expect(!after.contains(.fills) && after.contains(.strokes))
        // Nothing to clear: nothing written; a halftone override clears to unset.
        #expect(try a.perform(ClearGraphicStyleOverride([rect], category: .effects)) == nil)
        try a.perform(OpsCommand("Halftone", ops: [Ops.set(rect, [GraphicStyleFields.objectHalftone(.rect)], values: NodeValues.common(kind: .rect) { $0.halftone.frequency = 60 })]))
        if GraphicStyleDefaults.overrides(of: rect, in: a.state).contains(.halftone) {
            try a.perform(ClearGraphicStyleOverride([rect], category: .halftone))
            #expect(!GraphicStyleDefaults.overrides(of: rect, in: a.state).contains(.halftone))
        }
        #expect(StyleCategory(AppearanceList.effects) == .effects && StyleCategory(AppearanceList.strokes) == .strokes && StyleCategory(AppearanceList.fills) == .fills)
    }

    // MARK: Charts (DRAW-034)

    @Test func aPictographIsAChildSourceTheOverrideNamesAndRemoveDeletesIt() throws {
        var a = Replica(0xA)
        _ = try LayerFixture.layers(["Art"], on: &a)
        let chart = try ChartFixture.chart([["", "North"], ["\"Q1\"", "3"], ["\"Q2\"", "5"]], on: &a)
        let table = ChartFixture.model(chart, a).table
        let key = ChartElementKeyRef(series: OpID(table.series[0].id))
        var star = Wiretuner_Doc_V1_NodeProps()
        star.rect.size = .with { $0.width = 10; $0.height = 10 }
        let change = try #require(try a.perform(SetChartPictograph(chart, key: key, artwork: [NodeTree(props: star)], repeating: true)))
        #expect(change.label == "Pictograph")
        let source = try #require(RemoveChartPictograph.source(chart, key: key, in: a.state))
        #expect(Objects.parent(of: source, in: a.state) == chart && a.state.liveChildren(source).count == 1)
        #expect(ChartFixture.model(chart, a).liveOverrides(for: table)[key]?.repeating == true)
        // Again: the earlier source goes.
        try a.perform(SetChartPictograph(chart, key: key, artwork: [NodeTree(props: star), NodeTree(props: star)], repeating: false))
        #expect(!a.state.isLive(source))
        let second = try #require(RemoveChartPictograph.source(chart, key: key, in: a.state))
        #expect(a.state.liveChildren(second).count == 2)
        try a.perform(RemoveChartPictograph(chart, key: key))
        #expect(!a.state.isLive(second) && RemoveChartPictograph.source(chart, key: key, in: a.state) == nil)
        #expect(try a.perform(RemoveChartPictograph(chart, key: key)) == nil, "nothing left to remove")
        // Refusals.
        #expect(throws: ChartError.self) { try a.perform(SetChartPictograph(chart, key: key, artwork: [], repeating: false)) }
        #expect(throws: ChartError.self) { try a.perform(SetChartPictograph(chart, key: ChartElementKeyRef(series: rect(&a)), artwork: [NodeTree(props: star)], repeating: false)) }
        #expect(throws: ChartError.self) {
            try a.perform(SetChartPictograph(chart, key: ChartElementKeyRef(series: key.series, index: chart), artwork: [NodeTree(props: star)], repeating: false))
        }
        // An element key (series and category) takes a pictograph of its own.
        let element = ChartElementKeyRef(series: key.series, index: OpID(table.categories[0].id))
        try a.perform(SetChartPictograph(chart, key: element, artwork: [NodeTree(props: star)], repeating: false))
        #expect(RemoveChartPictograph.source(chart, key: element, in: a.state) != nil)
    }

    func rect(_ a: inout Replica) throws -> OpID { try PageFixture.rect(&a, at: Point(x: 500, y: 500)) }

    @Test func ungroupingAChartBakesItsDrawingAndDeletesIt() throws {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["Art"], on: &a)[0]
        let chart = try ChartFixture.chart([["", "North"], ["\"Q1\"", "3"]], on: &a)
        _ = try PageFixture.rect(&a, at: Point(x: 300, y: 300))
        let spec = try #require(ChartFixture.model(chart, a).spec(node: chart))
        let item = ChartLayout(spec: spec).displayItem(transform: Objects.pasteboardTransform(of: chart, in: a.state))
        let change = try #require(try a.perform(UngroupChart(chart, item: item)))
        #expect(change.label == "Ungroup" && !a.state.isLive(chart))
        let group = try #require(a.state.liveChildren(layer).first { a.state.nodeKind($0) == .group })
        #expect(!a.state.liveChildren(group).isEmpty)
        // An empty drawing still leaves a group; a chart no longer there is refused.
        let empty = try ChartFixture.chart([["1"]], on: &a)
        try a.perform(UngroupChart(empty, item: .group(GroupItem(children: []))))
        #expect(throws: ChartError.self) { try a.perform(UngroupChart(chart, item: item)) }
    }

    // MARK: Reading order (OBJ-041)

    struct Page3 {
        var pair: Pair
        let page: OpID
        let objects: [OpID]

        init() throws {
            var world = Pair()
            let page = try PageFixture.onePage(&world.a)
            _ = try LayerFixture.layers(["Art"], on: &world.a)
            var made: [OpID] = []
            for index in 0..<4 { made.append(try PageFixture.rect(&world.a, at: Point(x: 20 + Double(index) * 30, y: 20))) }
            world.sync()
            self.page = page
            objects = made
            pair = world
        }

        func order(_ replica: Replica) -> [OpID] {
            let pages = PageList(replica.state)
            return ReadingOrder.order(of: pages[page]!, in: replica.state, pages: pages)
        }
    }

    @Test func withoutAnOverrideThePageReadsInStackingOrderAndLaterObjectsAppend() throws {
        var world = try Page3()
        #expect(world.order(world.pair.a) == world.objects)
        let o = world.objects
        let change = try #require(try world.pair.a.perform(ArrangeReadingOrder(page: world.page, order: [o[3], o[1], o[0], o[2]])))
        #expect(change.label == "Reading Order")
        #expect(world.order(world.pair.a) == [o[3], o[1], o[0], o[2]])
        // Arranged already: nothing written.
        #expect(try world.pair.a.perform(ArrangeReadingOrder(page: world.page, order: [o[3], o[1], o[0], o[2]])) == nil)
        let later = try PageFixture.rect(&world.pair.a, at: Point(x: 20, y: 80))
        #expect(world.order(world.pair.a) == [o[3], o[1], o[0], o[2], later])
        // Decorative and off-page objects are not listed; a duplicate entry counts once.
        try world.pair.a.perform(SetDecorative([o[1]], decorative: true))
        let away = try PageFixture.rect(&world.pair.a, at: Point(x: 5000, y: 5000))
        #expect(!world.order(world.pair.a).contains(o[1]) && !world.order(world.pair.a).contains(away))
        try world.pair.a.perform(OpsCommand("Duplicate entry", ops: [Ops.elementInsert(world.page, ReadingOrder.sequence, positions: [[0xF0]],
                                                                                       values: ReadingOrder.values([.with { $0.node.id = o[3].proto }]))]))
        #expect(world.order(world.pair.a).filter { $0 == o[3] }.count == 1)
        try world.pair.a.perform(OpsCommand("Empty entry", ops: [Ops.elementInsert(world.page, ReadingOrder.sequence, positions: [[0xF8]], values: ReadingOrder.values([.init()]))]))
        #expect(ReadingOrder.entries(of: world.page, in: world.pair.a.state).contains { $0.node == nil })
        try world.pair.a.perform(ArrangeReadingOrder(page: world.page, order: [o[2], o[3]]))
        #expect(world.order(world.pair.a).prefix(2) == [o[2], o[3]])
        // A group without alt reads as its members.
        let pages = PageList(world.pair.a.state)
        #expect(ReadingOrder.readable(of: pages[world.page]!, in: world.pair.a.state, pages: pages).count == world.order(world.pair.a).count)
        // Use Stacking Order.
        try world.pair.a.perform(ClearReadingOrder(page: world.page))
        #expect(world.order(world.pair.a) == [o[0], o[2], o[3], later])
        #expect(try world.pair.a.perform(ClearReadingOrder(page: world.page)) == nil)
        #expect(throws: (any Error).self) { try world.pair.a.perform(ArrangeReadingOrder(page: o[0], order: [])) }
    }

    @Test func groupsWithoutAltReadAsTheirMembers() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        _ = try LayerFixture.layers(["Art"], on: &a)
        let one = try PageFixture.rect(&a, at: Point(x: 20, y: 20))
        let two = try PageFixture.rect(&a, at: Point(x: 60, y: 20))
        let inner = try #require(try a.perform(GroupObjects([one, two]))?.createdObjects.first { a.state.nodeKind($0) == .group })
        let three = try PageFixture.rect(&a, at: Point(x: 100, y: 20))
        let group = try #require(try a.perform(GroupObjects([inner, three]))?.createdObjects.first { a.state.nodeKind($0) == .group })
        let pages = PageList(a.state)
        #expect(ReadingOrder.readable(of: pages[page]!, in: a.state, pages: pages) == [one, two, three], "a nested group without alt too")
        try a.perform(SetAlt([group], alt: "Two squares"))
        #expect(ReadingOrder.readable(of: pages[page]!, in: a.state, pages: pages) == [group])
    }

    @Test func movesOfDifferentEntriesKeepBothAndOfTheSameEntryGoToTheGreaterOpID() throws {
        var world = try Page3()
        let o = world.objects
        try world.pair.a.perform(ArrangeReadingOrder(page: world.page, order: o))
        world.pair.sync()
        // Different entries: a moves o[0] to the end, b moves o[3] to the front.
        try world.pair.a.perform(ArrangeReadingOrder(page: world.page, order: [o[1], o[2], o[3], o[0]]))
        try world.pair.b.perform(ArrangeReadingOrder(page: world.page, order: [o[3], o[0], o[1], o[2]]))
        world.pair.sync()
        let merged = world.order(world.pair.a)
        #expect(merged == world.order(world.pair.b) && merged.first == o[3] && merged.last == o[0])
        // The same entry: both move o[1], one to the front, one to the end.
        let a = try #require(try world.pair.a.perform(ArrangeReadingOrder(page: world.page, order: [o[1]] + merged.filter { $0 != o[1] })))
        let b = try #require(try world.pair.b.perform(ArrangeReadingOrder(page: world.page, order: merged.filter { $0 != o[1] } + [o[1]])))
        world.pair.sync()
        let final = world.order(world.pair.a)
        #expect(final == world.order(world.pair.b))
        #expect(PageFixture.later(a, b) ? final.first == o[1] : final.last == o[1])
        // One deletes an object the other orders: both skip it.
        try world.pair.a.perform(DeleteNodes([o[2]]))
        try world.pair.b.perform(ArrangeReadingOrder(page: world.page, order: [o[2]] + final.filter { $0 != o[2] }))
        world.pair.sync()
        #expect(!world.order(world.pair.a).contains(o[2]) && world.order(world.pair.a) == world.order(world.pair.b))
        #expect(world.pair.a.state.stateHash == world.pair.b.state.stateHash)
        #expect(ArrangeReadingOrder.kept([nil, nil]).isEmpty)
    }
}
