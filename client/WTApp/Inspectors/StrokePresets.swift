import Foundation
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTRender

/// A dash in the *Dash* pop-up: its name and on/off lengths.  A stroke stores its own copy.
struct DashChoice: Hashable, Codable, Sendable {
    var name: String
    var lengths: [Double]

    /// The stored value a stroke copies.
    var pattern: Wiretuner_Doc_V1_DashPattern {
        var pattern = Wiretuner_Doc_V1_DashPattern()
        pattern.name = name
        pattern.lengths = lengths
        return pattern
    }

    /// A name for a dash made in the Dash Editor: its lengths ("4-2-1-2").
    static func name(for lengths: [Double]) -> String {
        lengths.map { $0.formatted(.number.precision(.fractionLength(0...2))) }.joined(separator: "-")
    }
}

/// Custom dashes and arrowheads saved on this Mac (stroke-attributes.adoc, "Data model"):
/// `~/Library/Application Support/WireTuner/Presets/`, `dashes.json` and `arrowheads.json`
/// (each arrowhead its encoded `Arrowhead`, base64).  Strokes never depend on them: every stroke
/// stores its own copy, so removing a preset changes no document.
@MainActor
@Observable
final class StrokePresetStore {
    let directory: URL
    private(set) var dashes: [DashChoice] = []
    private(set) var arrowheads: [Wiretuner_Doc_V1_Arrowhead] = []

    static let shared = StrokePresetStore(directory: defaultDirectory)

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "WireTuner/Presets")
    }

    init(directory: URL) {
        self.directory = directory
        load()
    }

    var dashesURL: URL { directory.appending(path: "dashes.json") }
    var arrowheadsURL: URL { directory.appending(path: "arrowheads.json") }

    func load() {
        dashes = (try? JSONDecoder().decode([DashChoice].self, from: Data(contentsOf: dashesURL))) ?? []
        let encoded = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: arrowheadsURL))) ?? []
        arrowheads = encoded.compactMap { Data(base64Encoded: $0).flatMap { try? Wiretuner_Doc_V1_Arrowhead(serializedBytes: $0) } }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(dashes).write(to: dashesURL)
        let encoded = arrowheads.compactMap { try? $0.serializedData().base64EncodedString() }
        try? JSONEncoder().encode(encoded).write(to: arrowheadsURL)
    }

    /// Saves `dash` unless a dash with its lengths is already saved.
    func add(_ dash: DashChoice) {
        guard !dashes.contains(where: { $0.lengths == dash.lengths }) else { return }
        dashes.append(dash)
        save()
    }

    func removeDash(at index: Int) {
        guard dashes.indices.contains(index) else { return }
        dashes.remove(at: index)
        save()
    }

    /// Saves `head` unless an arrowhead of that shape is already saved.
    func add(_ head: Wiretuner_Doc_V1_Arrowhead) {
        guard !arrowheads.contains(where: { $0.contours == head.contours && $0.filled == head.filled }) else { return }
        arrowheads.append(head)
        save()
    }

    func removeArrowhead(at index: Int) {
        guard arrowheads.indices.contains(index) else { return }
        arrowheads.remove(at: index)
        save()
    }
}

/// The Dash Editor sheet's fields (stroke-attributes.adoc, "Dashes"): up to four *On* and four
/// *Off* lengths in points.  The pattern is the pairs up to the first empty one.
struct DashEditorModel: Equatable {
    var on: [String] = ["", "", "", ""]
    var off: [String] = ["", "", "", ""]

    /// The editor loaded with `lengths` (an kbd:[Option]-clicked dash).
    init(lengths: [Double] = []) {
        let format = { (value: Double) in value.formatted(.number.precision(.fractionLength(0...3))) }
        for (index, value) in lengths.prefix(8).enumerated() {
            if index.isMultiple(of: 2) { on[index / 2] = format(value) } else { off[index / 2] = format(value) }
        }
    }

    /// The on, off, on, off... lengths; nil when a field does not read as a length or every
    /// length is zero.
    var lengths: [Double]? {
        var result: [Double] = []
        for pair in 0..<4 {
            let onText = on[pair].trimmingCharacters(in: .whitespaces), offText = off[pair].trimmingCharacters(in: .whitespaces)
            if onText.isEmpty && offText.isEmpty { break }
            guard let onValue = Self.length(onText), let offValue = Self.length(offText) else { return nil }
            result += [onValue, offValue]
        }
        return result.contains { $0 > 0 } ? result : nil
    }

    /// A length in points: empty reads 0; anything `Measure` refuses, or a negative, is nil.
    static func length(_ text: String) -> Double? {
        guard !text.isEmpty else { return 0 }
        guard let value = try? Measure.parse(text, unit: .points), value >= 0 else { return nil }
        return value
    }

    /// btn:[OK]: the dash, named by its lengths.
    var choice: DashChoice? {
        lengths.map { DashChoice(name: DashChoice.name(for: $0), lengths: $0) }
    }
}

/// The Dash Editor sheet.
struct DashEditorSheet: View {
    @State var model: DashEditorModel
    let apply: (DashChoice) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dash Editor").font(.headline)
            Grid(alignment: .leading) {
                GridRow {
                    Text("On")
                    ForEach(0..<4, id: \.self) { index in
                        TextField("On \(index + 1)", text: $model.on[index]).frame(width: 48).accessibilityIdentifier("dash.on.\(index)")
                    }
                }
                GridRow {
                    Text("Off")
                    ForEach(0..<4, id: \.self) { index in
                        TextField("Off \(index + 1)", text: $model.off[index]).frame(width: 48).accessibilityIdentifier("dash.off.\(index)")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("dash.cancel")
                Button("OK", action: Self.ok(model, apply: apply)).keyboardShortcut(.defaultAction).disabled(model.choice == nil)
                    .accessibilityIdentifier("dash.ok")
            }
        }
        .padding()
    }

    static func ok(_ model: DashEditorModel, apply: @escaping (DashChoice) -> Void) -> () -> Void {
        { model.choice.map(apply) }
    }
}

/// *Manage Dashes…* and *Manage Arrowheads…*: the custom presets saved on this Mac, each with a
/// delete button.
struct ManagePresetsSheet: View {
    let title: String
    let names: [String]
    let remove: (Int) -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if names.isEmpty {
                Text("No custom presets are saved on this Mac.").foregroundStyle(.secondary)
            }
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack {
                    Text(name)
                    Spacer()
                    Button("Delete", action: Self.delete(index, remove: remove)).accessibilityIdentifier("presets.delete.\(index)")
                }
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction).accessibilityIdentifier("presets.done")
            }
        }
        .padding()
        .frame(minWidth: 260)
    }

    static func delete(_ index: Int, remove: @escaping (Int) -> Void) -> () -> Void {
        { remove(index) }
    }
}
