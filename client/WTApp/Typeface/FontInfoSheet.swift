import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel

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
        shows = Dictionary(uniqueKeysWithValues: SetMetricGuides.Line.allCases.map { ($0, Self.isShown($0, in: info.guides)) })
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
        guard let namesCommand = namesCommand(), let metricsCommand = metricsCommand(), let os2Command = os2Command() else { return nil }
        result += [namesCommand, metricsCommand, os2Command].compactMap { $0 }
        if let guides = guidesCommand() { result.append(guides) }
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
            embedding: embedding == os2.embedding ? nil : embedding
        )
        let unchanged = command.weightClass == nil && command.widthClass == nil && command.vendorID == nil && command.bold == nil
            && command.italic == nil && command.embedding == nil
        return .some(unchanged ? nil : command)
    }

    private func guidesCommand() -> (any WTModel.Command)? {
        let edits = SetMetricGuides.Line.allCases.compactMap { line -> SetMetricGuides.Edit? in
            let shown = shows[line, default: true]
            return shown == Self.isShown(line, in: original.guides) ? nil : .show(line, shown)
        }
        return edits.isEmpty ? nil : SetMetricGuides(edits)
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
        var upmCommands: [any WTModel.Command] = []
        if upm != original.metrics.upm {
            let command = SetUnitsPerEm(upm, scale: scaleGlyphs)
            upmCommands = (try? command.changes(in: document.state)) ?? [command]
        }
        return Task {
            for command in commands { _ = await document.perform(command).value }
            if !upmCommands.isEmpty { _ = await document.performGroup(upmCommands).value }
        }
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
        case .guides:
            ForEach(SetMetricGuides.Line.allCases, id: \.self) { line in
                Toggle(FontInfoModel.title(of: line), isOn: binding(line))
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
