import AppKit
import WTCRDT
import WTInterchange
import WTModel
import WTRender

/// One open Print dialog (PRINT-003, PRINT-004): the *{product}* pane, the `PrintPlanView` the
/// operation prints and the print info the panel edits, kept consistent while the dialog is open.
///
/// * The plan is made again -- and the view resized -- whenever what it depends on changes: a pane
///   commit or a collaborator's change once it is applied (the document revision), the job's
///   *Print* choice or *Selected objects only*, or the panel's paper.
/// * After every document change the pane's settings are written into the print info's
///   dictionary as `WTPrint*` keys (`PrintPresets.preset`), so the panel's *Presets* menu saves
///   them with the paper and printer.  When the print info holds settings the document does not
///   have, a preset was chosen: they are written to the document as one `ApplyPrintPreset`.
@MainActor
final class PrintSession {
    let document: DocumentHandle
    let pane: PrintPaneModel
    let accessory: PrintAccessoryController
    let view: PrintPlanView
    let blobs: BlobPlacement
    /// The print info the panel edits (the operation's).
    var info: NSPrintInfo
    private(set) var paper: PrintPaper
    private(set) var plan: PrintPlan
    /// Plans made after the view's own (the tests count them).
    private(set) var rebuilds = 0
    /// Presets applied from the print info.
    private(set) var presetsApplied = 0
    private var key: Key
    private var applying = false
    private var observations: [DocumentHandle.ObservationToken] = []

    /// What the plan was made from.
    struct Key: Equatable {
        var revision: Int?
        var source: PrintSource
        var selection: Set<NodeID>?
        var paper: PrintPaper
    }

    init(document: DocumentHandle, info: NSPrintInfo, selection: Set<NodeID>?, imageStore: ImageStore?, blobs: BlobPlacement,
         fonts: PrintFontChecker? = nil, perform: @escaping @MainActor (any WTModel.Command) -> Void) {
        self.document = document
        self.info = info
        self.blobs = blobs
        let pane = PrintPaneModel(document: document, selection: selection, perform: perform)
        pane.fontChecker = fonts
        self.pane = pane
        let paper = PrintJob.paper(info)
        self.paper = paper
        let plan = PrintJob.plan(document, source: pane.effectiveSource, paper: paper, selection: pane.effectiveSelection, blobs: blobs)
        self.plan = plan
        key = Key(revision: document.model?.revision, source: pane.effectiveSource, selection: pane.effectiveSelection, paper: paper)
        view = PrintPlanView(plan: plan, renderer: PrintJob.renderer(imageStore: imageStore), title: document.title)
        pane.show(plan)
        accessory = PrintAccessoryController(model: pane)
        pane.onChange = { [weak self] in
            self?.refresh()
            self?.accessory.revision += 1
        }
        accessory.onPrintInfo = { [weak self] in self?.loadPreset() }
        view.isPreview = { [weak accessory] in accessory?.isShowing ?? false }
        view.onPaperChange = { [weak self] paper in self?.paperChanged(paper) }
        writePreset()
    }

    /// Follows the document while the dialog is open.
    func start() {
        let refresh: @MainActor () -> Void = { [weak self] in self?.documentChanged() }
        observations = [document.observe { _ in refresh() }, document.observeStructure(refresh)]
    }

    func end() {
        for token in observations { document.stopObserving(token) }
        observations = []
    }

    /// A change applied to the document (local or remote): the print info follows it, the plan is
    /// made again and the panel's preview repaginates.
    func documentChanged() {
        guard refresh() else { return }
        accessory.revision += 1
    }

    func paperChanged(_ paper: PrintPaper) {
        self.paper = paper
        refresh()
    }

    /// Makes the plan again when what it depends on changed; true when it did.
    @discardableResult
    func refresh() -> Bool {
        let current = Key(revision: document.model?.revision, source: pane.effectiveSource, selection: pane.effectiveSelection, paper: paper)
        guard current != key else { return false }
        if current.revision != key.revision {
            applying = false
            writePreset()
        }
        key = current
        plan = PrintJob.plan(document, source: current.source, paper: paper, selection: current.selection, blobs: blobs)
        rebuilds += 1
        view.show(plan)
        pane.show(plan)
        return true
    }

    // MARK: Presets

    /// The document's pane settings as `WTPrint*` entries.
    var documentPreset: [String: Any] {
        let preset = PrintPresets.preset(document.state)
        return preset.preset.dictionary(includeHiddenLayers: preset.includeHiddenLayers)
    }

    /// Writes the document's pane settings into the print info's dictionary.
    func writePreset() {
        let dictionary = info.dictionary()
        for (key, value) in documentPreset { dictionary[key] = value }
    }

    /// The `WTPrint*` entries of the print info, keyed by string.
    var infoEntries: [String: Any] {
        var entries: [String: Any] = [:]
        for (key, value) in info.dictionary() {
            if let key = key as? String, key.hasPrefix(PrintPreset.Key.prefix) { entries[key] = value }
        }
        return entries
    }

    /// Applies the preset the print info holds when it differs from the document (a preset was
    /// chosen in the panel), once until the change lands.
    func loadPreset() {
        guard !applying, let loaded = PrintPreset.read(infoEntries), let current = PrintPreset.read(documentPreset),
              loaded.preset != current.preset || loaded.includeHiddenLayers != current.includeHiddenLayers else { return }
        applying = true
        presetsApplied += 1
        pane.perform(ApplyPrintPreset(loaded.preset, includeHiddenLayers: loaded.includeHiddenLayers))
    }
}
