import WTCRDT

/// *Export Data…* (data-merge.adoc, "Exporting data"; DATA-022): the resolved records -- after
/// mapping, formats and transforms -- as a table for CSV, with the chosen fields in the Data
/// panel's order, the chosen record range and an optional leading `record` column holding each
/// record's number in the merge.  A field without a name is left out (a CSV column needs one); a
/// record without a value for a field writes an empty cell.
public struct DataExport: Hashable, Sendable {
    /// The fields to write (all named fields when nil).
    public var fields: Set<OpID>?
    /// The 1-based record numbers to write (every record when nil); clamped to the records.
    public var range: ClosedRange<Int>?
    /// Whether the first column is `record`.
    public var recordColumn: Bool

    public init(fields: Set<OpID>? = nil, range: ClosedRange<Int>? = nil, recordColumn: Bool = true) {
        self.fields = fields
        self.range = range
        self.recordColumn = recordColumn
    }

    /// The name of the record-number column.
    public static let recordColumnName = "record"

    /// The fields of `records` this export writes, in order.
    public func columns(of records: RecordSet) -> [DataFieldInfo] {
        records.fields.filter { !$0.name.isEmpty && (fields?.contains($0.id) ?? true) }
    }

    /// The records this export writes.
    public func rows(of records: RecordSet) -> [RecordSet.Record] {
        guard let range else { return records.records }
        return records.records.filter { range.contains($0.number) }
    }

    /// The table: `record` (when chosen), then each chosen field by name, formatted values.
    public func table(_ records: RecordSet) -> DataTable {
        let fields = columns(of: records)
        let rows = rows(of: records).map { record in
            var values: [String: String] = recordColumn ? [Self.recordColumnName: String(record.number)] : [:]
            for field in fields {
                let value = record.value(field.id)
                if value.raw != nil { values[field.name] = value.text }
            }
            return DataRecord(values)
        }
        return DataTable(columns: (recordColumn ? [Self.recordColumnName] : []) + fields.map(\.name), records: rows)
    }

    /// The CSV a spreadsheet opens: UTF-8 with a byte-order mark.
    public func csv(_ records: RecordSet) -> String {
        table(records).csv(bom: true)
    }
}
