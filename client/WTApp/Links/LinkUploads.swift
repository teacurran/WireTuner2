import SwiftUI
import WTInterchange
import WTCRDT
import WTModel

/// The Links window's *Uploading* badge and the Object panel's btn:[Links…] (linking-embedding.adoc,
/// "The Links window"; DOC-023's remainder): an imported file whose blob is still waiting to upload
/// from this Mac shows "Uploading" beside its status; the Object panel of a placed image or file
/// opens the Links window with its row selected.
@MainActor
enum LinkUploads {
    /// The blobs (hex SHA-256) waiting to upload from this Mac for a window's document.
    static var pending: @MainActor (DocumentWindowController) -> Set<String> = { _ in [] }
    /// Opens the Links window on the front document with `asset`'s row selected.
    static var showLinks: @MainActor (OpID) -> Void = { _ in }

    static func isUploading(_ sha256: Data, in window: DocumentWindowController) -> Bool {
        pending(window).contains(ImportedBlob.hex(sha256))
    }

    /// The status column with the badge.
    static func status(_ status: String, uploading: Bool) -> String {
        uploading ? "\(status) · Uploading" : status
    }

    /// The asset the selected objects place, when they are all images or placed files of one asset.
    static func asset(of nodes: [OpID], in state: EngineState) -> OpID? {
        let sources = nodes.map { node -> OpID? in
            switch state.props(node).kind {
            case .image(let image)?: image.hasSource ? OpID(image.source.id) : nil
            case .placedFile(let file)?: file.hasSource ? OpID(file.source.id) : nil
            default: nil
            }
        }
        guard let first = sources.first, let asset = first, sources.allSatisfy({ $0 == asset }) else { return nil }
        return asset
    }

    /// The Object panel section: btn:[Links…] for the selected image or placed file.
    static let section = InspectorSection(id: "links", order: 95, kinds: nil) { panel in
        guard let asset = asset(of: panel.objects.map(\.id), in: panel.document.state) else { return nil }
        return AnyView(LinksSectionView(asset: asset))
    }
}

struct LinksSectionView: View {
    let asset: OpID

    static func open(_ asset: OpID) -> () -> Void { { LinkUploads.showLinks(asset) } }

    var body: some View {
        Form {
            Button("Links…", action: Self.open(asset))
                .help("Open the Links window on this file: relink, update, embed or extract it")
                .accessibilityIdentifier("object.links")
        }
        .padding(.horizontal)
    }
}
