import Observation
import SwiftUI
import WTCRDT
import WTModel

/// The options of *Export Data…* in its save panel (data-merge.adoc, "Exporting data"; DATA-022):
/// the fields to write (all named fields at first), all records or a range of record numbers,
/// and whether to include the `record` column.
@MainActor
@Observable
final class DataExportOptionsModel {
    struct Field: Identifiable, Equatable {
        let id: OpID
        let name: String
    }

    let fields: [Field]
    let recordCount: Int
    var chosen: Set<OpID>
    var allRecords = true
    var from = 1
    var to: Int
    var recordColumn = true

    init(records: RecordSet) {
        fields = records.fields.filter { !$0.name.isEmpty }.map { Field(id: $0.id, name: $0.name) }
        recordCount = records.count
        chosen = Set(fields.map(\.id))
        to = max(records.count, 1)
    }

    /// The export the panel's choices describe.
    var export: DataExport {
        let low = min(max(from, 1), max(recordCount, 1))
        let high = min(max(to, low), max(recordCount, 1))
        return DataExport(fields: chosen, range: allRecords ? nil : low...high, recordColumn: recordColumn)
    }

    func binding(_ field: OpID) -> Binding<Bool> {
        Binding(get: { self.chosen.contains(field) }, set: { on in if on { self.chosen.insert(field) } else { self.chosen.remove(field) } })
    }
}

/// The save panel's accessory.
struct DataExportOptionsView: View {
    @Bindable var model: DataExportOptionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fields").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.fields) { field in
                        Toggle(field.name, isOn: model.binding(field.id)).accessibilityIdentifier("dataExport.field.\(field.name)")
                    }
                }
            }
            .frame(maxHeight: 120)
            Picker("Records", selection: $model.allRecords) {
                Text("All \(model.recordCount)").tag(true)
                Text("Range").tag(false)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("dataExport.records")
            HStack {
                TextField("From", value: $model.from, format: .number).frame(width: 60)
                Text("to")
                TextField("To", value: $model.to, format: .number).frame(width: 60)
            }
            .disabled(model.allRecords)
            Toggle("Include the record column", isOn: $model.recordColumn).accessibilityIdentifier("dataExport.recordColumn")
        }
        .padding(12)
        .frame(width: 360)
    }
}
