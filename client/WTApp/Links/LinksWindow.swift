import AppKit
import SwiftUI
import WTCRDT
import WTModel

/// The Links window's body (linking-embedding.adoc, "The Links window"): the table of imported
/// files and the actions under it, with *Info* for the selected row.
struct LinksView: View {
    @Bindable var model: LinksModel

    /// The table's selection: choosing a row selects its objects.
    static func selection(_ model: LinksModel) -> Binding<OpID?> {
        Binding(get: { model.selection }, set: { model.select($0) })
    }

    var body: some View {
        let _ = model.document.model?.revision
        VStack(alignment: .leading, spacing: 8) {
            Table(model.rows, selection: Self.selection(model)) {
                TableColumn("Name") { row in
                    HStack(spacing: 4) {
                        if row.isLibrary { Image(systemName: "cloud") }
                        Text(row.name).italic(row.isBroken)
                    }
                }
                TableColumn("Kind", value: \.kind)
                TableColumn("Size", value: \.size)
                TableColumn("Page", value: \.page)
                TableColumn("Status", value: \.status)
            }
            .frame(minHeight: 180)
            .accessibilityIdentifier("links.table")
            HStack {
                let row = model.rows.first { $0.id == model.selection }
                Button("Info", action: model.showInfo).disabled(row == nil).accessibilityIdentifier("links.info")
                Button("Change…", action: model.changeSelected).disabled(row == nil).accessibilityIdentifier("links.change")
                Button("Update", action: model.updateSelected).disabled(row?.canUpdate != true).accessibilityIdentifier("links.update")
                Button("Update All", action: model.updateAllLinks).accessibilityIdentifier("links.updateAll")
                Button("Embed", action: model.embedSelected).disabled(row == nil || row?.status == "Embedded").accessibilityIdentifier("links.embed")
                Button("Extract…", action: model.extractSelected).disabled(row == nil).accessibilityIdentifier("links.extract")
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.red).accessibilityIdentifier("links.message") }
            if let id = model.info {
                GroupBox("Info") {
                    ForEach(model.infoLines(id), id: \.0) { line in
                        HStack(alignment: .top) {
                            Text(line.0).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                            Text(line.1).textSelection(.enabled)
                        }
                    }
                }
                .accessibilityIdentifier("links.infoBox")
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 280)
    }
}

/// The Links window (menu:Edit[Links…]): one window, showing the front document's links.
@MainActor
final class LinksWindowController: NSWindowController {
    static let identifier = NSUserInterfaceItemIdentifier("links-window")
    private(set) var model: LinksModel

    init(model: LinksModel) {
        self.model = model
        let window = NSWindow(contentViewController: NSHostingController(rootView: LinksView(model: model)))
        window.title = "Links — \(model.document.title)"
        window.identifier = Self.identifier
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LinksWindowController is built in code")
    }

    /// Shows `model`'s document instead.
    func show(_ model: LinksModel) {
        self.model = model
        window?.contentViewController = NSHostingController(rootView: LinksView(model: model))
        window?.title = "Links — \(model.document.title)"
    }
}
