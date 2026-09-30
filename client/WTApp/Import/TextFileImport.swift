import AppKit
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel

// TYPE-008's app half (importing-text.adoc, "Importing a text file"): menu:File[Import…] and the
// Finder take `.rtf`, `.rtfd`, `.txt` and `.md` files as text blocks.  Under the import pointer a
// click makes an auto-expanding block at that point and a drag a fixed-size block of that frame; a
// drop is a click at the drop point.  The file is read off the main actor (`TextImporter`, with
// the *Encoding* option of the Import panel's accessory for plain text), an RTFD's pictures are
// stored as blobs first, and `ImportText` places the block in one change "Import text", selected,
// with the import summary as its note and in the status bar.
extension ImportController {
    /// The text files the Import panel offers.
    static let textFileTypes: [UTType] = [.rtf, .rtfd, .plainText] + (UTType(filenameExtension: "md").map { [$0] } ?? [])

    /// Whether `url` is a text file the text importer reads.
    static func isTextFile(_ url: URL) -> Bool {
        TextFileFormat(pathExtension: url.pathExtension) != nil
    }

    /// The *Encoding* pop-up's choices: *Automatic* (the guess) first.
    static let textEncodings: [(name: String, encoding: String.Encoding?)] = [
        ("Automatic", nil), ("UTF-8", .utf8), ("UTF-16", .utf16), ("Mac Roman", .macOSRoman), ("Windows Latin 1 (Windows-1252)", .windowsCP1252),
        ("ISO Latin 1", .isoLatin1), ("Japanese (Shift JIS)", .shiftJIS),
    ]

    /// Where the chosen encoding is remembered (this Mac's defaults, as the formats' options are).
    static let textEncodingKey = "import.text.encoding"

    /// The index of the chosen *Encoding* in `textEncodings`.
    var textEncodingChoice: Int {
        get {
            let index = preferences.defaults.integer(forKey: Self.textEncodingKey)
            return Self.textEncodings.indices.contains(index) ? index : 0
        }
        set { preferences.defaults.set(newValue, forKey: Self.textEncodingKey) }
    }

    /// The block frame for a text file placed where `placement` says: a click is an
    /// auto-expanding block there, a marquee a fixed-size block of that frame.
    static func textFrame(_ placement: ImportPlacement) -> CreateTextBlock.Frame {
        switch placement {
        case .at(let point): .point(point)
        case .fit(let rect, _): .area(rect)
        }
    }

    /// Reads the text file `url` and places it as one block at `frame`, recording the result in
    /// `outcome`.
    func placeText(_ url: URL, on window: DocumentWindowController, frame: CreateTextBlock.Frame, into outcome: inout ImportOutcome) async {
        let name = url.lastPathComponent
        let options = TextImportOptions(encoding: Self.textEncodings[textEncodingChoice].encoding)
        let document = window.documentHandle
        do {
            let file = try await Task.detached(priority: .userInitiated) { try TextImporter.read(url: url, options: options) }.value
            let command = ImportText(file, frame: frame, layer: window.objectEditing.activeLayer)
            try await blobs.store(command.blobs, for: document)
            let target = ImportTarget.resolve(preferred: window.objectEditing.activeLayer, in: document.state)
            guard let change = await window.objectEditing.perform(command).value,
                  let block = change.createdObjects.first(where: { document.state.nodeKind($0) == .text }) else {
                outcome.failures.append("“\(name)” could not be placed.")
                return
            }
            outcome.placed.append(block)
            outcome.notes += file.notes.map { "\(name): \($0)" }
            if target.fellBack { outcome.movedTo = LayerOrder(document.state).layer(of: block, in: document.state) }
        } catch let error as TextImportError {
            outcome.failures.append(Self.failure(error, name: name))
        } catch {
            outcome.failures.append(Self.failure(error, name: name))
        }
    }
}

extension ImportController {
    /// What the alert says about a text file that could not be read.
    static func failure(_ error: TextImportError, name: String) -> String {
        switch error {
        case .unreadable(let format): "“\(name)” could not be imported: it is not a readable \(format.displayName) file."
        case .undecodable(let encoding): "“\(name)” could not be imported: it is not \(String.localizedName(of: encoding)) text.  Choose another encoding in the Import panel."
        }
    }
}

extension TextFileFormat {
    /// What the Import panel's accessory says about a selected file.
    var displayName: String {
        switch self {
        case .rtf: "Rich Text (RTF)"
        case .rtfd: "Rich Text with Attachments (RTFD)"
        case .plain: "Plain Text"
        case .markdown: "Markdown"
        }
    }
}
