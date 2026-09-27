import AppKit
@preconcurrency import CoreText
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender

/// One glyph of the Metrics window's setting.
struct MetricsSetting: Hashable {
    struct Item: Hashable {
        /// The glyph set, nil for a character the font has no glyph for (drawn as a box).
        let glyph: OpID?
        let character: String
        /// Where its origin sits, font units from the start of the line.
        let x: Double
        let advance: Double
        /// The kerning applied after it (to the next glyph).
        let kern: Double
        let outline: FilledPath
    }

    let items: [Item]
    /// The width of the whole line, font units.
    var width: Double { items.last.map { $0.x + $0.advance + $0.kern } ?? 0 }

    /// The line `text` sets in `state`: each character's glyph by codepoint, its advance, and the
    /// kerning to the next glyph (`Kerning.value`), with the flattened outlines the generator uses.
    static func layout(_ text: String, in state: EngineState, kerning: Bool = true) -> MetricsSetting {
        let index = GlyphIndex(state)
        let kerns = Kerning(state, index: index)
        let glyphs = text.unicodeScalars.map { index.glyph(for: $0.value) }
        let missingAdvance = Double(WTModel.FontInfo(state).metrics.upm) / 2
        let sources = glyphs.contains { $0 != nil } ? GlyphOutlines.sources(in: state, index: index) : [:]
        var outlines: [OpID: FilledPath] = [:]
        var items: [Item] = []
        var x = 0.0
        for (position, scalar) in text.unicodeScalars.enumerated() {
            let glyph = glyphs[position]
            let next = position + 1 < glyphs.count ? glyphs[position + 1] : nil
            let kern = kerning ? glyph.flatMap { left in next.map { kerns.value(left.id, $0.id) } } ?? 0 : 0
            var outline = FilledPath.empty
            if let cached = glyph.flatMap({ outlines[$0.id] }) {
                outline = cached
            } else if let glyph {
                outline = GlyphFlattener.outline(of: NodeID(glyph.id), sources: sources).path
                outlines[glyph.id] = outline
            }
            let advance = glyph?.advanceWidth ?? missingAdvance
            items.append(Item(glyph: glyph?.id, character: String(Character(scalar)), x: x, advance: advance, kern: kern, outline: outline))
            x += advance + kern
        }
        return MetricsSetting(items: items)
    }
}

/// menu:Font[Metrics Window] (kerning-metrics.adoc, "The Metrics window"; FONT-020): a sample
/// line set from the glyphs with their kerning; clicking between two glyphs selects the pair, whose
/// kerning is typed or nudged (by 10 units, 1 with Option); *Class* kerns the two glyphs' classes
/// instead.  The table lists every kerning pair, and the preview line shapes the same text with
/// Core Text from a quick compile of the font (`FontCompiler.quickCompile`), with the features the
/// *Features* pop-up turns on or off (`PreviewFeatures`: the automatic ones, then the feature
/// file's once it checks clean, else a warning).
@MainActor
@Observable
final class MetricsModel {
    struct PairRow: Identifiable, Hashable {
        let id: OpID
        let left: String
        let right: String
        let value: Double
    }

    @ObservationIgnored let document: DocumentHandle
    var text = "AVATAR To LT" {
        didSet { if text != oldValue { reload() } }
    }
    var pointSize = 96.0
    var kerningOn = true {
        didSet { if kerningOn != oldValue { reload() } }
    }
    private(set) var setting = MetricsSetting(items: [])
    private(set) var upm = 1_000.0
    private(set) var ascender = 800.0
    /// The selected pair: the glyph at this position and the next one.
    private(set) var selected: Int?
    var kernText = ""
    /// Kern the pair's classes instead of the pair.
    var byClass = false
    private(set) var pairs: [PairRow] = []
    private(set) var problem: String?
    /// The compiled preview font, once a quick compile finished.
    private(set) var previewFont: CTFont?
    private(set) var previewStatus = ""
    /// The *Features* pop-up: what it lists (read with each compile) and which are on.
    private(set) var features = PreviewFeatures()
    private(set) var enabledFeatures: Set<String> = []
    /// The features someone turned on or off in the pop-up, kept across compiles.
    @ObservationIgnored private var chosenFeatures: [String: Bool] = [:]
    /// The compiled font before the features are applied.
    @ObservationIgnored private var compiledFont: CTFont?
    /// The preview's compile: a quick compile of the font (replaced in tests).
    @ObservationIgnored var compile: @Sendable (FontSource) async throws -> Data = { try await FontCompiler().quickCompile($0).data }

    init(document: DocumentHandle) {
        self.document = document
        reload()
    }

    /// Reads the setting and the pairs again (after any change).
    func reload() {
        let state = document.state
        let metrics = WTModel.FontInfo(state).metrics
        upm = Double(metrics.upm)
        ascender = metrics.ascender
        setting = MetricsSetting.layout(text, in: state, kerning: kerningOn)
        let index = GlyphIndex(state)
        pairs = Kerning(state, index: index).effectivePairs.map {
            PairRow(id: $0.id, left: index[$0.left]?.name ?? "?", right: index[$0.right]?.name ?? "?", value: $0.value)
        }
        if let selected, selected + 1 >= setting.items.count { self.selected = nil }
        if let pair = selectedPair { kernText = FontUnits.format(Kerning(state, index: index).value(pair.left, pair.right)) }
    }

    /// The glyphs of the selected pair, nil unless both are glyphs.
    var selectedPair: (left: OpID, right: OpID)? {
        guard let selected, setting.items.indices.contains(selected + 1),
              let left = setting.items[selected].glyph, let right = setting.items[selected + 1].glyph else { return nil }
        return (left, right)
    }

    /// Selects the pair after the glyph at `position`.
    func select(_ position: Int?) {
        selected = position.flatMap { setting.items.indices.contains($0 + 1) ? $0 : nil }
        problem = nil
        reload()
    }

    /// A click at `x` font units along the line: the pair whose join is nearest.
    func click(atX x: Double) {
        let joins = setting.items.dropLast().enumerated().map { ($0.offset, abs($0.element.x + $0.element.advance + $0.element.kern - x)) }
        select(joins.min { $0.1 < $1.1 }?.0)
    }

    static let noPair = "Click between two glyphs"
    static let noClasses = "Both glyphs need a kerning class"

    /// Commits the Kern field for the selected pair (or its classes).
    @discardableResult
    func commitKern() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let value = FontUnits.parse(kernText) else {
            problem = GlyphBarModel.invalidNumber
            return nil
        }
        return setKern(value)
    }

    /// The arrow keys: the selected pair's kerning by `delta`.
    @discardableResult
    func nudge(by delta: Double) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let pair = selectedPair else {
            problem = Self.noPair
            return nil
        }
        return setKern(Kerning(document.state).value(pair.left, pair.right) + delta)
    }

    private func setKern(_ value: Double) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let pair = selectedPair else {
            problem = Self.noPair
            return nil
        }
        let command: any WTModel.Command
        if byClass {
            let kerning = Kerning(document.state)
            guard let left = kerning.kernClass(of: pair.left, side: .left), let right = kerning.kernClass(of: pair.right, side: .right) else {
                problem = Self.noClasses
                return nil
            }
            command = SetClassKern(left.id, right.id, to: value)
        } else {
            command = SetKernPair(pair.left, pair.right, to: value)
        }
        return run(command)
    }

    /// btn:[Remove Pair]: the selected pair's own kerning.
    @discardableResult
    func removePair() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let pair = selectedPair else {
            problem = Self.noPair
            return nil
        }
        return run(RemoveKernPairs([(pair.left, pair.right)]))
    }

    /// btn:[Remove All Kerning].
    @discardableResult
    func removeAll() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        run(RemoveAllKerning())
    }

    private func run(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        problem = nil
        let task = document.perform(command)
        Task { [weak self] in
            _ = await task.value
            self?.reload()
        }
        return task
    }

    /// The preview: a quick compile of the font, loaded with Core Text and shaped with the
    /// features the pop-up has on.
    @discardableResult
    func compilePreview() -> Task<Bool, Never> {
        let snapshot = FontGeneration.snapshot(document.state)
        let size = pointSize
        let compile = compile
        previewStatus = "Compiling…"
        setFeatures(PreviewFeatures.of(snapshot.source))
        return Task { [weak self] in
            guard let data = try? await compile(snapshot.source),
                  let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider) else {
                self?.previewStatus = "The font does not compile yet"
                self?.compiledFont = nil
                self?.previewFont = nil
                return false
            }
            self?.compiledFont = CTFontCreateWithGraphicsFont(font, size, nil, nil)
            self?.applyFeatures()
            self?.previewStatus = ""
            return true
        }
    }

    /// Lists `features`, each on as someone chose it or else as it is by default.
    private func setFeatures(_ features: PreviewFeatures) {
        self.features = features
        enabledFeatures = Set(features.items.filter { chosenFeatures[$0.tag] ?? $0.isOnByDefault }.map(\.tag))
    }

    /// A feature turned on or off in the pop-up: the preview reshapes at once, without compiling.
    func setFeature(_ tag: String, on: Bool) {
        guard features.items.contains(where: { $0.tag == tag }) else { return }
        chosenFeatures[tag] = on
        if on { enabledFeatures.insert(tag) } else { enabledFeatures.remove(tag) }
        applyFeatures()
    }

    func isFeatureOn(_ tag: String) -> Bool { enabledFeatures.contains(tag) }

    private func applyFeatures() {
        previewFont = compiledFont.map { features.font($0, enabled: enabledFeatures) }
    }

    /// The setting as paths in view space for a view `height` tall: each glyph scaled to
    /// `pointSize`, the baseline at the ascender below the top, with its x offset.
    func paths(height: Double) -> [(path: CGPath, box: CGRect?, x: Double)] {
        let scale = pointSize / upm
        let baseline = min(ascender * scale + 12, height)
        return setting.items.map { item in
            let transform = CGAffineTransform(translationX: 12 + item.x * scale, y: baseline).scaledBy(x: scale, y: scale)
            let path = Self.cgPath(DisplayPath(contours: item.outline.contours), transform: transform)
            let box = item.glyph == nil ? CGRect(x: 12 + item.x * scale, y: baseline - ascender * scale, width: item.advance * scale, height: ascender * scale) : nil
            return (path, box, 12 + item.x * scale)
        }
    }
}

extension MetricsModel {
    /// `path` as a `CGPath` under `transform`.
    static func cgPath(_ path: DisplayPath, transform: CGAffineTransform) -> CGPath {
        let result = CGMutablePath()
        func point(_ point: Point) -> CGPoint { CGPoint(x: point.x, y: point.y) }
        for element in path.elements {
            switch element {
            case .move(let to): result.move(to: point(to), transform: transform)
            case .line(let to): result.addLine(to: point(to), transform: transform)
            case .quadCurve(let control, let end): result.addQuadCurve(to: point(end), control: point(control), transform: transform)
            case .cubicCurve(let control1, let control2, let end):
                result.addCurve(to: point(end), control1: point(control1), control2: point(control2), transform: transform)
            case .close: result.closeSubpath()
            }
        }
        return result
    }
}

struct MetricsView: View {
    @Bindable var model: MetricsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Sample text", text: $model.text).accessibilityIdentifier("metrics.text")
                Toggle("Kern", isOn: $model.kerningOn)
            }
            MetricsSettingRepresentable(model: model)
                .frame(height: 160)
                .accessibilityIdentifier("metrics.setting")
            HStack {
                Text("Kern")
                TextField("Kern", text: $model.kernText).frame(width: 70).onSubmit(model.submitKern).accessibilityIdentifier("metrics.kern")
                Toggle("Class", isOn: $model.byClass)
                Button("−10", action: model.nudgeDown)
                Button("+10", action: model.nudgeUp)
                Button("Remove Pair", action: model.removePairButton)
                Spacer()
                Button("Remove All Kerning", action: model.removeAllButton)
            }
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Preview Compiled Font", action: model.previewButton)
                MetricsFeaturesMenu(model: model)
                Text(model.previewStatus).font(.caption).foregroundStyle(.secondary)
            }
            if let warning = model.features.warning {
                Text(warning).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("metrics.featuresWarning")
            }
            if let font = model.previewFont {
                Text(model.text).font(Font(font)).lineLimit(1).accessibilityIdentifier("metrics.preview")
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(model.pairs) { pair in
                        HStack {
                            Text(pair.left).frame(width: 100, alignment: .leading)
                            Text(pair.right).frame(width: 100, alignment: .leading)
                            Text(FontUnits.format(pair.value))
                        }
                    }
                }
            }
            .frame(minHeight: 120)
        }
        .padding()
        .frame(minWidth: 560, minHeight: 520)
    }
}

extension MetricsModel {
    // The window's buttons.
    func submitKern() { commitKern() }
    func nudgeDown() { nudge(by: -10) }
    func nudgeUp() { nudge(by: 10) }
    func removePairButton() { removePair() }
    func removeAllButton() { removeAll() }
    func previewButton() { compilePreview() }
}

/// The *Features* pop-up: a switch per feature the preview can shape with (FONT-020); empty until
/// the preview has compiled once.
struct MetricsFeaturesMenu: View {
    let model: MetricsModel

    var body: some View {
        Menu("Features") {
            if model.features.items.isEmpty {
                Text("Preview the compiled font to list its features")
            }
            ForEach(model.features.items) { item in
                Toggle(item.isAutomatic ? "\(item.tag) (automatic)" : item.tag, isOn: binding(item.tag))
            }
            if let warning = model.features.warning { Text(warning) }
        }
        .fixedSize()
        .accessibilityIdentifier("metrics.features")
    }

    func binding(_ tag: String) -> Binding<Bool> {
        Binding(get: { model.isFeatureOn(tag) }, set: { model.setFeature(tag, on: $0) })
    }
}

/// The setting line of the Metrics window, drawn in AppKit.
struct MetricsSettingRepresentable: NSViewRepresentable {
    let model: MetricsModel

    func makeNSView(context: Context) -> MetricsSettingView { MetricsSettingView(model: model) }

    func updateNSView(_ view: MetricsSettingView, context: Context) { view.needsDisplay = true }
}

/// The sample line: the glyphs' outlines, a box for a character without a glyph, the selected
/// join in the accent colour.  A click selects the pair nearest to it.
@MainActor
final class MetricsSettingView: NSView {
    let model: MetricsModel

    init(model: MetricsModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 160))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MetricsSettingView is built in code") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let context = NSGraphicsContext.current!.cgContext
        let entries = model.paths(height: bounds.height)
        for entry in entries {
            context.addPath(entry.path)
            context.setFillColor(NSColor.labelColor.cgColor)
            context.fillPath()
            if let box = entry.box {
                context.setStrokeColor(NSColor.systemRed.cgColor)
                context.stroke(box)
            }
        }
        if let selected = model.selected, entries.indices.contains(selected + 1) {
            context.setFillColor(NSColor.controlAccentColor.cgColor)
            context.fill(CGRect(x: entries[selected + 1].x - 1, y: 4, width: 2, height: bounds.height - 8))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        model.click(atX: (point.x - 12) * model.upm / model.pointSize)
        needsDisplay = true
    }
}

/// The Metrics window of one document; follows the document's changes.
@MainActor
final class MetricsWindowController: NSWindowController, NSWindowDelegate {
    let model: MetricsModel
    var onClose: (@MainActor () -> Void)?
    private var token: DocumentHandle.ObservationToken?

    init(document: DocumentHandle) {
        model = MetricsModel(document: document)
        let window = NSWindow(contentViewController: NSHostingController(rootView: MetricsView(model: model)))
        window.title = "Metrics — \(document.title)"
        window.identifier = NSUserInterfaceItemIdentifier("typeface.metrics")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        token = document.observe { [weak self] _ in self?.model.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MetricsWindowController is built in code") }

    func windowWillClose(_ notification: Notification) {
        if let token { model.document.stopObserving(token) }
        token = nil
        onClose?()
    }
}
