import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// menu:Font[Font Info…] (font-info.adoc; FONT-006): the Names, Metrics, OS/2, Guides and
/// Features panes.  The fields start from the document as it is when the sheet opens; btn:[OK]
/// writes only the fields the user changed -- one change per pane ("Font Info: Names"…), so a
/// collaborator's concurrent edit of another field is kept -- and a new units per em with *Scale
/// glyphs* rescales the font in one undo step.
@MainActor
@Observable
final class FontInfoModel {
    enum Pane: String, CaseIterable, Identifiable {
        case names = "Names", metrics = "Metrics", os2 = "OS/2", guides = "Guides", features = "Features"
        var id: String { rawValue }
    }

    @ObservationIgnored let document: DocumentHandle
    var pane: Pane = .names
    var names: [FontNameField: String]
    var metrics: [FontMetricField: String]
    var upmText: String
    var scaleGlyphs = true
    var weightText: String
    var widthText: String
    var vendor: String
    var bold: Bool
    var italic: Bool
    var embedding: WTModel.FontInfo.Embedding
    var shows: [SetMetricGuides.Line: Bool]
    var extraLineName = ""
    var extraLineY = ""
    /// The font's extra metric lines as the Guides pane edits them (FONT-006): name, height (font
    /// units, y up) and whether btn:[−] removed it.
    struct LineRow: Identifiable, Hashable {
        let id: OpID
        var name: String
        var y: String
        var removed = false
    }
    var lines: [LineRow]
    /// The OS/2 pane's ten PANOSE digits (FONT-006).
    var panose: [UInt8]
    /// The Guides pane's colour wells (FONT-006): each line colour as shown, the default palette's when unset.
    var wellColors: [SetMetricGuides.ColorWell: CGColor]
    /// btn:[Use Default Colors]: the three wells cleared back to the default palette on btn:[OK].
    var useDefaultColors = false
    /// Shows the progress sheet of a large rescale and returns what closes it (FONT-006; set by the features).
    @ObservationIgnored var showProgress: @MainActor (String) -> @MainActor () -> Void = { _ in {} }
    var generateKern: Bool
    var generateMark: Bool
    var generateLiga: Bool
    private(set) var problem: String?
    @ObservationIgnored private let original: WTModel.FontInfo

    init(document: DocumentHandle) {
        self.document = document
        let info = WTModel.FontInfo(document.state)
        original = info
        names = Dictionary(uniqueKeysWithValues: FontNameField.allCases.map { ($0, Self.value(of: $0, in: info.names)) })
        metrics = Dictionary(uniqueKeysWithValues: FontMetricField.allCases.map { ($0, FontUnits.format(Self.value(of: $0, in: info.metrics))) })
        upmText = String(info.metrics.upm)
        weightText = String(info.os2.weightClass)
        widthText = String(info.os2.widthClass)
        vendor = info.os2.vendorID
        bold = info.os2.bold
        italic = info.os2.italic
        embedding = info.os2.embedding
        panose = info.os2.panose
        wellColors = Dictionary(uniqueKeysWithValues: SetMetricGuides.ColorWell.allCases.map { ($0, Self.color(of: $0, in: info.guides).cgColor) })
        shows = Dictionary(uniqueKeysWithValues: SetMetricGuides.Line.allCases.map { ($0, Self.isShown($0, in: info.guides)) })
        lines = info.guides.extraLines.map { LineRow(id: $0.id, name: $0.name, y: FontUnits.format($0.y)) }
        generateKern = !info.omitGeneratedKern
        generateMark = !info.omitGeneratedMark
        generateLiga = !info.omitGeneratedLiga
    }

    static func value(of field: FontNameField, in names: WTModel.FontInfo.Names) -> String {
        switch field {
        case .family: names.family
        case .style: names.style
        case .postscript: names.storedPostscript
        case .full: names.full
        case .version: names.version
        case .copyright: names.copyright
        case .trademark: names.trademark
        case .designer: names.designer
        case .designerURL: names.designerURL
        case .manufacturer: names.manufacturer
        case .manufacturerURL: names.manufacturerURL
        case .description: names.description
        case .sampleText: names.sampleText
        case .license: names.license
        case .licenseURL: names.licenseURL
        }
    }

    static func value(of field: FontMetricField, in metrics: WTModel.FontInfo.Metrics) -> Double {
        switch field {
        case .ascender: metrics.ascender
        case .descender: metrics.descender
        case .xHeight: metrics.xHeight
        case .capHeight: metrics.capHeight
        case .italicAngle: metrics.italicAngle
        case .underlinePosition: metrics.underlinePosition
        case .underlineThickness: metrics.underlineThickness
        case .lineGap: metrics.lineGap
        case .typoAscender: metrics.typoAscender
        case .typoDescender: metrics.typoDescender
        case .typoLineGap: metrics.typoLineGap
        }
    }

    static func isShown(_ line: SetMetricGuides.Line, in guides: WTModel.FontInfo.Guides) -> Bool {
        switch line {
        case .baseline: guides.showBaseline
        case .xHeight: guides.showXHeight
        case .capHeight: guides.showCapHeight
        case .ascender: guides.showAscender
        case .descender: guides.showDescender
        case .sideBearings: guides.showSideBearings
        case .emBox: guides.showEmBox
        case .labels: guides.showLabels
        }
    }

    /// A well's colour: the font's, else the default palette's.
    static func color(of well: SetMetricGuides.ColorWell, in guides: WTModel.FontInfo.Guides) -> RenderColor {
        let defaults = GlyphCanvasFrame(advanceWidth: 0)
        switch well {
        case .baseline: return guides.baselineColor ?? defaults.baselineColor
        case .metric: return guides.metricColor ?? defaults.metricColor
        case .bearing: return guides.bearingColor ?? defaults.bearingColor
        }
    }

    /// `color` as stored: sRGB components (nil for a colour that cannot be converted).
    static func stored(_ color: CGColor) -> RenderColor? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB), let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let parts = converted.components, parts.count >= 3 else { return nil }
        return RenderColor(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]))
    }

    static func title(of well: SetMetricGuides.ColorWell) -> String {
        switch well {
        case .baseline: "Baseline color"
        case .metric: "Metric line color"
        case .bearing: "Side bearing color"
        }
    }

    /// The well of `well` in the Guides pane.
    func binding(_ well: SetMetricGuides.ColorWell) -> Binding<CGColor> {
        Binding(get: { self.wellColors[well] ?? CGColor(gray: 0, alpha: 1) }, set: {
            self.wellColors[well] = $0
            self.useDefaultColors = false
        })
    }

    /// The pop-up of PANOSE digit `digit`.
    func binding(panose digit: Int) -> Binding<UInt8> {
        Binding(get: { self.panose[digit] }, set: { self.panose[digit] = $0 })
    }

    static func title(of field: FontNameField) -> String {
        switch field {
        case .family: "Family"
        case .style: "Style"
        case .postscript: "PostScript name"
        case .full: "Full name"
        case .version: "Version"
        case .copyright: "Copyright"
        case .trademark: "Trademark"
        case .designer: "Designer"
        case .designerURL: "Designer URL"
        case .manufacturer: "Manufacturer"
        case .manufacturerURL: "Manufacturer URL"
        case .description: "Description"
        case .sampleText: "Sample text"
        case .license: "License"
        case .licenseURL: "License URL"
        }
    }

    static func title(of field: FontMetricField) -> String {
        switch field {
        case .ascender: "Ascender"
        case .descender: "Descender"
        case .xHeight: "x-height"
        case .capHeight: "Cap height"
        case .italicAngle: "Italic angle"
        case .underlinePosition: "Underline position"
        case .underlineThickness: "Underline thickness"
        case .lineGap: "Line gap"
        case .typoAscender: "Typo ascender"
        case .typoDescender: "Typo descender"
        case .typoLineGap: "Typo line gap"
        }
    }

    static func title(of line: SetMetricGuides.Line) -> String {
        switch line {
        case .baseline: "Baseline"
        case .xHeight: "x-height"
        case .capHeight: "Cap height"
        case .ascender: "Ascender"
        case .descender: "Descender"
        case .sideBearings: "Side bearings"
        case .emBox: "Em box"
        case .labels: "Labels"
        }
    }

    // MARK: Committing

    /// The commands btn:[OK] performs, in pane order, or nil with `problem` set when a field is
    /// invalid (the sheet stays open).
    func commands() -> [any WTModel.Command]? {
        problem = nil
        var result: [any WTModel.Command] = []
        guard let namesCommand = namesCommand(), let metricsCommand = metricsCommand(), let os2Command = os2Command(),
              let guidesCommand = guidesCommand() else { return nil }
        result += [namesCommand, metricsCommand, os2Command, guidesCommand].compactMap { $0 }
        guard let guidesLine = extraLineCommand() else { return nil }
        result += guidesLine.map { [$0] } ?? []
        if let features = featuresCommand() { result.append(features) }
        return result
    }

    private func fail(_ message: String) -> (any WTModel.Command)?? {
        problem = message
        return nil
    }

    private func namesCommand() -> (any WTModel.Command)?? {
        var changed: [FontNameField: String] = [:]
        for field in FontNameField.allCases where names[field] != Self.value(of: field, in: original.names) {
            changed[field] = names[field, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let postscript = changed[.postscript], !postscript.isEmpty, !WTModel.FontInfo.isValidPostScriptName(postscript) {
            return fail("The PostScript name may use only letters, digits, “.”, “_” and “-”, up to 63 characters")
        }
        if let version = changed[.version], !version.isEmpty, !WTModel.FontInfo.isValidVersion(version) {
            return fail("Type the version as a number with three decimals, such as 1.000")
        }
        for field in [FontNameField.designerURL, .manufacturerURL, .licenseURL] {
            if let url = changed[field], !url.isEmpty, URL(string: url)?.scheme == nil {
                return fail("\(Self.title(of: field)) must be a full URL, such as https://example.com")
            }
        }
        return .some(changed.isEmpty ? nil : SetFontNames(changed))
    }

    private func metricsCommand() -> (any WTModel.Command)?? {
        var changed: [FontMetricField: Double] = [:]
        for field in FontMetricField.allCases {
            let text = metrics[field, default: ""]
            guard text != FontUnits.format(Self.value(of: field, in: original.metrics)) else { continue }
            guard let value = FontUnits.parse(text), field == .italicAngle ? abs(value) <= 90 : abs(value) <= 32_767 else {
                return fail("\(Self.title(of: field)) must be a number of font units")
            }
            changed[field] = value
        }
        return .some(changed.isEmpty ? nil : SetFontMetrics(changed))
    }

    private func os2Command() -> (any WTModel.Command)?? {
        let os2 = original.os2
        guard let weight = Int(weightText), (1...1_000).contains(weight), let width = Int(widthText), (1...9).contains(width) else {
            return fail("Weight is 1 to 1000 and width 1 to 9")
        }
        guard vendor == os2.vendorID || WTModel.FontInfo.isValidVendor(vendor) else { return fail("The vendor ID is four printable ASCII characters") }
        let command = SetFontOS2(
            weightClass: weight == os2.weightClass ? nil : weight, widthClass: width == os2.widthClass ? nil : width,
            vendorID: vendor == os2.vendorID ? nil : vendor, bold: bold == os2.bold ? nil : bold, italic: italic == os2.italic ? nil : italic,
            embedding: embedding == os2.embedding ? nil : embedding, panose: panose == os2.panose ? nil : panose
        )
        let unchanged = command.weightClass == nil && command.widthClass == nil && command.vendorID == nil && command.bold == nil
            && command.italic == nil && command.embedding == nil && command.panose == nil
        return .some(unchanged ? nil : command)
    }

    private func guidesCommand() -> (any WTModel.Command)?? {
        var edits = SetMetricGuides.Line.allCases.compactMap { line -> SetMetricGuides.Edit? in
            let shown = shows[line, default: true]
            return shown == Self.isShown(line, in: original.guides) ? nil : .show(line, shown)
        }
        for well in SetMetricGuides.ColorWell.allCases {
            let current = Self.color(of: well, in: original.guides)
            if useDefaultColors {
                if Self.isSet(well, in: original.guides) { edits.append(.color(well, nil)) }
            } else if let chosen = wellColors[well].flatMap({ Self.stored($0) }), !Self.same(chosen, current) {
                edits.append(.color(well, chosen))
            }
        }
        let stored = Dictionary(uniqueKeysWithValues: original.guides.extraLines.map { ($0.id, $0) })
        for row in lines {
            guard let line = stored[row.id] else { continue }
            if row.removed {
                edits.append(.removeLine(row.id))
                continue
            }
            let name = row.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let y = FontUnits.parse(row.y), abs(y) <= 32_767 else { return fail("Each extra line needs a name and a height") }
            if name != line.name || y != line.y { edits.append(.editLine(row.id, name: name == line.name ? nil : name, y: y == line.y ? nil : y)) }
        }
        return .some(edits.isEmpty ? nil : SetMetricGuides(edits))
    }

    /// Whether the font stores a colour for `well`.
    static func isSet(_ well: SetMetricGuides.ColorWell, in guides: WTModel.FontInfo.Guides) -> Bool {
        switch well {
        case .baseline: guides.baselineColor != nil
        case .metric: guides.metricColor != nil
        case .bearing: guides.bearingColor != nil
        }
    }

    /// Colours equal to well within what a colour well round-trips.
    static func same(_ a: RenderColor, _ b: RenderColor) -> Bool {
        abs(a.red - b.red) < 0.002 && abs(a.green - b.green) < 0.002 && abs(a.blue - b.blue) < 0.002
    }

    /// btn:[Use Default Colors].
    func useDefaultPalette() {
        let defaults = WTModel.FontInfo(EngineState()).guides
        for well in SetMetricGuides.ColorWell.allCases { wellColors[well] = Self.color(of: well, in: defaults).cgColor }
        useDefaultColors = true
    }

    /// btn:[−] on an extra line (and again to keep it).
    func toggleRemoved(_ id: OpID) {
        guard let at = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[at].removed.toggle()
    }

    /// btn:[Use SIL Open Font License] (font-info.adoc, "License"): the License and License URL
    /// fields filled with the OFL 1.1 notice, the copyright line of the Names pane first.
    func useOpenFontLicense() {
        let copyright = names[.copyright, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = SetFontNames.openFontLicense(copyright: copyright).values
        let notice = preset[.license] ?? ""
        names[.license] = copyright.isEmpty ? notice : "\(copyright)\n\n\(notice)"
        names[.licenseURL] = preset[.licenseURL] ?? ""
    }

    private func extraLineCommand() -> (any WTModel.Command)?? {
        let name = extraLineName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty || !extraLineY.isEmpty else { return .some(nil) }
        guard !name.isEmpty, let y = FontUnits.parse(extraLineY), abs(y) <= 32_767 else { return fail("Type a name and a height for the new line") }
        return .some(SetMetricGuides([.addLine(name: name, y: y)]))
    }

    private func featuresCommand() -> (any WTModel.Command)? {
        let kern = generateKern == !original.omitGeneratedKern ? nil : generateKern
        let mark = generateMark == !original.omitGeneratedMark ? nil : generateMark
        let liga = generateLiga == !original.omitGeneratedLiga ? nil : generateLiga
        return kern == nil && mark == nil && liga == nil ? nil : SetGeneratedFeatures(kern: kern, mark: mark, liga: liga)
    }

    static let invalidUPM = "Units per em must be a whole number from 16 to 16384"

    /// btn:[OK]: the panes' changes, then a new units per em (scaled in one undo step).  Returns
    /// the task that applies them, nil when a field is invalid.
    @discardableResult
    func commit() -> Task<Void, Never>? {
        guard let upm = Int(upmText.trimmingCharacters(in: .whitespaces)), WTModel.FontInfo.upmRange.contains(upm) else {
            problem = Self.invalidUPM
            return nil
        }
        guard let commands = commands() else { return nil }
        let document = document
        guard upm != original.metrics.upm else {
            return Task {
                for command in commands { _ = await document.perform(command).value }
            }
        }
        let command = SetUnitsPerEm(upm, scale: scaleGlyphs)
        let glyphs = GlyphIndex(document.state).count
        // A big rescale is built off the main thread behind a progress sheet (FONT-006).
        let progress = scaleGlyphs && glyphs > Self.progressThreshold ? showProgress(Self.progressText(glyphs: glyphs, upm: upm)) : nil
        return Task {
            for command in commands { _ = await document.perform(command).value }
            let state = document.state
            let upmCommands: [any WTModel.Command] = await Task.detached { (try? command.changes(in: state)) ?? [command] }.value
            _ = await document.performGroup(upmCommands).value
            progress?()
        }
    }

    /// Above this many glyphs a rescale shows the progress sheet.
    static let progressThreshold = 500

    static func progressText(glyphs: Int, upm: Int) -> String {
        "Scaling \(glyphs.formatted()) glyphs to \(upm) units per em…"
    }

    /// The sheet's OK button: closes when the fields are valid.
    func ok() -> Bool { commit() != nil }
}

struct FontInfoSheet: View {
    @Bindable var model: FontInfoModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Font Info").font(.headline)
            Picker("Pane", selection: $model.pane) {
                ForEach(FontInfoModel.Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("fontInfo.pane")
            ScrollView {
                Form { pane }.padding(.trailing, 8)
            }
            .frame(height: 340)
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red).accessibilityIdentifier("fontInfo.problem") }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("OK", action: SheetButtons.closing(model.ok, close)).keyboardShortcut(.defaultAction).accessibilityIdentifier("fontInfo.ok")
            }
        }
        .padding()
        .frame(width: 480)
    }

    @ViewBuilder private var pane: some View {
        switch model.pane {
        case .names:
            ForEach(FontNameField.allCases, id: \.self) { field in
                TextField(FontInfoModel.title(of: field), text: binding(field))
            }
            Button("Use SIL Open Font License", action: model.useOpenFontLicense).accessibilityIdentifier("fontInfo.ofl")
        case .metrics:
            TextField("Units per em", text: $model.upmText).accessibilityIdentifier("fontInfo.upm")
            Toggle("Scale glyphs to the new em", isOn: $model.scaleGlyphs)
            ForEach(FontMetricField.allCases, id: \.self) { field in
                TextField(FontInfoModel.title(of: field), text: binding(field))
            }
        case .os2:
            TextField("Weight class", text: $model.weightText)
            TextField("Width class", text: $model.widthText)
            TextField("Vendor ID", text: $model.vendor)
            Toggle("Bold", isOn: $model.bold)
            Toggle("Italic", isOn: $model.italic)
            Picker("Embedding", selection: $model.embedding) {
                ForEach(WTModel.FontInfo.Embedding.allCases, id: \.self) { Text(String(describing: $0).capitalized).tag($0) }
            }
            Text("PANOSE").font(.subheadline)
            ForEach(Array(FontPanose.digits.enumerated()), id: \.offset) { digit, entry in
                Picker(entry.title, selection: model.binding(panose: digit)) {
                    ForEach(FontPanose.choices(digit, value: model.panose[digit]), id: \.value) { Text($0.title).tag($0.value) }
                }
                .accessibilityIdentifier("fontInfo.panose.\(digit)")
            }
        case .guides:
            ForEach(SetMetricGuides.Line.allCases, id: \.self) { line in
                Toggle(FontInfoModel.title(of: line), isOn: binding(line))
            }
            ForEach(SetMetricGuides.ColorWell.allCases, id: \.self) { well in
                ColorPicker(FontInfoModel.title(of: well), selection: model.binding(well), supportsOpacity: false)
                    .accessibilityIdentifier("fontInfo.color.\(well)")
            }
            Button("Use Default Colors", action: model.useDefaultPalette).accessibilityIdentifier("fontInfo.defaultColors")
            ForEach($model.lines) { $line in
                HStack {
                    TextField("Name", text: $line.name).disabled(line.removed)
                    TextField("Height", text: $line.y).frame(width: 70).disabled(line.removed)
                    Button(line.removed ? "Keep" : "−") { model.toggleRemoved(line.id) }.help(line.removed ? "Keep this line" : "Remove this line")
                }
            }
            TextField("New line name", text: $model.extraLineName)
            TextField("New line height", text: $model.extraLineY)
        case .features:
            Toggle("Generate kerning (kern)", isOn: $model.generateKern)
            Toggle("Generate mark attachment (mark, mkmk)", isOn: $model.generateMark)
            Toggle("Generate ligatures (liga)", isOn: $model.generateLiga)
        }
    }

    private func binding(_ field: FontNameField) -> Binding<String> { model.binding(field) }
    private func binding(_ field: FontMetricField) -> Binding<String> { model.binding(field) }
    private func binding(_ line: SetMetricGuides.Line) -> Binding<Bool> { model.binding(line) }
}

extension FontInfoModel {
    /// The field of `field` in the Names pane.
    func binding(_ field: FontNameField) -> Binding<String> {
        Binding(get: { self.names[field, default: ""] }, set: { self.names[field] = $0 })
    }

    /// The field of `field` in the Metrics pane.
    func binding(_ field: FontMetricField) -> Binding<String> {
        Binding(get: { self.metrics[field, default: ""] }, set: { self.metrics[field] = $0 })
    }

    /// The checkbox of `line` in the Guides pane.
    func binding(_ line: SetMetricGuides.Line) -> Binding<Bool> {
        Binding(get: { self.shows[line, default: true] }, set: { self.shows[line] = $0 })
    }
}

/// The PANOSE classification the OS/2 pane edits (font-info.adoc, "OS/2"): ten digits, each a pop-up of the
/// Latin Text family's names (PANOSE 1.0); a stored value past the names shows as its number.
enum FontPanose {
    static let digits: [(title: String, names: [String])] = [
        ("Family kind", ["Any", "No Fit", "Latin Text", "Latin Hand Written", "Latin Decorative", "Latin Symbol"]),
        ("Serif style", ["Any", "No Fit", "Cove", "Obtuse Cove", "Square Cove", "Obtuse Square Cove", "Square", "Thin", "Oval", "Exaggerated",
                         "Triangle", "Normal Sans", "Obtuse Sans", "Perpendicular Sans", "Flared", "Rounded"]),
        ("Weight", ["Any", "No Fit", "Very Light", "Light", "Thin", "Book", "Medium", "Demi", "Bold", "Heavy", "Black", "Extra Black"]),
        ("Proportion", ["Any", "No Fit", "Old Style", "Modern", "Even Width", "Extended", "Condensed", "Very Extended", "Very Condensed", "Monospaced"]),
        ("Contrast", ["Any", "No Fit", "None", "Very Low", "Low", "Medium Low", "Medium", "Medium High", "High", "Very High"]),
        ("Stroke variation", ["Any", "No Fit", "No Variation", "Gradual/Diagonal", "Gradual/Transitional", "Gradual/Vertical", "Gradual/Horizontal",
                              "Rapid/Vertical", "Rapid/Horizontal", "Instant/Vertical", "Instant/Horizontal"]),
        ("Arm style", ["Any", "No Fit", "Straight Arms/Horizontal", "Straight Arms/Wedge", "Straight Arms/Vertical", "Straight Arms/Single Serif",
                       "Straight Arms/Double Serif", "Non-Straight/Horizontal", "Non-Straight/Wedge", "Non-Straight/Vertical",
                       "Non-Straight/Single Serif", "Non-Straight/Double Serif"]),
        ("Letterform", ["Any", "No Fit", "Normal/Contact", "Normal/Weighted", "Normal/Boxed", "Normal/Flattened", "Normal/Rounded",
                        "Normal/Off Center", "Normal/Square", "Oblique/Contact", "Oblique/Weighted", "Oblique/Boxed", "Oblique/Flattened",
                        "Oblique/Rounded", "Oblique/Off Center", "Oblique/Square"]),
        ("Midline", ["Any", "No Fit", "Standard/Trimmed", "Standard/Pointed", "Standard/Serifed", "High/Trimmed", "High/Pointed", "High/Serifed",
                     "Constant/Trimmed", "Constant/Pointed", "Constant/Serifed", "Low/Trimmed", "Low/Pointed", "Low/Serifed"]),
        ("x-height", ["Any", "No Fit", "Constant/Small", "Constant/Standard", "Constant/Large", "Ducking/Small", "Ducking/Standard", "Ducking/Large"]),
    ]

    /// The pop-up's items for `digit`: its names, and `value` as a number when past them.
    static func choices(_ digit: Int, value: UInt8) -> [(value: UInt8, title: String)] {
        let names = digits[digit].names
        var result = names.enumerated().map { (UInt8($0.offset), $0.element) }
        if Int(value) >= names.count { result.append((value, "Value \(value)")) }
        return result
    }
}

extension TypefaceFeatures {
    /// The progress sheet of a large rescale on `window`; returns what closes it.
    func presentProgress(_ text: String, on window: NSWindow?) -> @MainActor () -> Void {
        var close: (@MainActor () -> Void)?
        _ = present("sheet.rescaleProgress", on: window) { dismiss in
            close = dismiss
            return RescaleProgressView(text: text)
        }
        return { close?() }
    }
}

/// The progress sheet a rescale of a font over 500 glyphs shows while its change group is built and applied.
struct RescaleProgressView: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(text).accessibilityIdentifier("rescale.progress")
        }
        .padding(24)
        .frame(width: 320)
    }
}
