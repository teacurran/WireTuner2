// The imported page's tree (IMG-009): every drawn object is emitted with the scopes around it --
// clipping paths, optional-content layers, transparency groups -- ordered by when they began, and
// consecutive objects under the same scopes share one group, so a page's structure comes back as
// nested clipping groups and layer groups rather than one group per object.

import Foundation
import WTGeometry

/// A clipping path, a layer or a group the content stream opened.
struct PDFImportScope {
    enum Kind {
        case clip(ImportedPath)
        case layer(String)
        case group(opacity: Double)
    }

    let id: Int
    let kind: Kind
}

/// What a whole import shares: the options, notes, fonts and the scope counter.
final class PDFImportSession {
    let name: String
    let text: ImportTextHandling
    /// The grey level unsupported shadings are filled with (0.1 for PDF, 0.5 for Illustrator
    /// gradient meshes).
    let meshBlack: Double
    private(set) var notes: [String] = []
    private var fonts: [UnsafeRawPointer: PDFImportFont] = [:]
    private var nextID = 0
    var missingFonts = Set<String>()

    init(name: String, text: ImportTextHandling, meshBlack: Double) {
        self.name = name
        self.text = text
        self.meshBlack = meshBlack
    }

    /// Records `note` once.
    func note(_ note: String) {
        if !notes.contains(note) {
            notes.append(note)
        }
    }

    func scope(_ kind: PDFImportScope.Kind) -> PDFImportScope {
        nextID += 1
        return PDFImportScope(id: nextID, kind: kind)
    }

    func font(_ dict: PDFImportDict) -> PDFImportFont {
        if let font = fonts[dict.id] {
            return font
        }
        let font = PDFImportFont(dict)
        fonts[dict.id] = font
        return font
    }

    /// The fill of shadings the importer cannot represent.
    var meshPaint: ImportedPaint {
        .solid(.init(cyan: 0, magenta: 0, yellow: 0, black: meshBlack))
    }
}

/// Assembles emitted objects into groups by their scopes.
final class PDFImportTree {
    private var root: [ImportedNode] = []
    private var open: [(scope: PDFImportScope, children: [ImportedNode])] = []
    /// A text node still accepting runs on its baseline.
    private var pendingText: (text: ImportedText, scopes: [Int])?

    func emit(_ node: ImportedNode, scopes: [PDFImportScope]) {
        flushText()
        place(node, scopes: scopes)
    }

    /// Adds a text run: joined to the text node before it when that one is on the same
    /// baseline under the same scopes with no other object between them.
    func emitText(_ run: ImportedTextRun, transform: AffineTransform, scopes: [PDFImportScope]) {
        let ids = scopes.map(\.id)
        if var pending = pendingText, pending.scopes == ids, transform.isIdentity, pending.text.transform.isIdentity,
           let last = pending.text.runs.last, abs(last.origin.y - run.origin.y) < 0.01 {
            pending.text.runs.append(run)
            pendingText = pending
            return
        }
        flushText()
        sync(scopes)
        pendingText = (ImportedText(runs: [run], transform: transform), ids)
    }

    func flushText() {
        guard let pending = pendingText else {
            return
        }
        pendingText = nil
        append(.text(pending.text))
    }

    private func place(_ node: ImportedNode, scopes: [PDFImportScope]) {
        sync(scopes)
        append(node)
    }

    private func append(_ node: ImportedNode) {
        if open.isEmpty {
            root.append(node)
        } else {
            open[open.count - 1].children.append(node)
        }
    }

    /// Closes the groups `scopes` is not inside and opens the ones it is.
    private func sync(_ scopes: [PDFImportScope]) {
        var common = 0
        while common < open.count, common < scopes.count, open[common].scope.id == scopes[common].id {
            common += 1
        }
        while open.count > common {
            close()
        }
        for scope in scopes.dropFirst(common) {
            open.append((scope, []))
        }
    }

    private func close() {
        let (scope, children) = open.removeLast()
        let group: ImportedGroup
        switch scope.kind {
        case .clip(let path):
            group = ImportedGroup(children: children, clip: path)
        case .layer(let name):
            group = ImportedGroup(children: children, name: name, role: .layer)
        case .group(let opacity):
            group = ImportedGroup(children: children, opacity: opacity)
        }
        append(.group(group))
    }

    /// Every node, all groups closed.
    func finish() -> [ImportedNode] {
        flushText()
        while !open.isEmpty {
            close()
        }
        return root
    }
}
