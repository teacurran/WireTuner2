import AppKit
import WTInterchange

/// The spooled half of a print job (PRINT-013; print-performance.adoc, "Watching and cancelling
/// a job"): once the Print dialog's btn:[Print] starts the job, the print view hands every sheet
/// to a `PrintRun` over the plan -- the snapshot taken at btn:[Print] -- which reports the sheet
/// it draws to the progress panel over the document window (`Drawing sheet 3 of 8, Page 1,
/// Magenta`, a bar, btn:[Cancel]).  btn:[Cancel] (or kbd:[Esc]) cancels the run: no further sheet
/// is drawn, the snapshot is released at once and the print context is destroyed, so nothing
/// more reaches the printer.
///
/// The view draws on the main actor (an `NSView` is main-actor code under Swift 6, so AppKit's
/// separate print thread is not used); the panel is redrawn and its button and kbd:[Esc] are
/// handled at each sheet boundary, where the job looks at the cancel flag.
@MainActor
final class PrintSpooler {
    let panel: PrintProgressPanel
    private weak var window: NSWindow?
    private(set) var run: PrintRun?
    private var ended = false
    /// Ends the print job after a cancel (the running operation's context); replaceable in tests.
    var destroyContext: @MainActor () -> Void = { NSPrintOperation.current?.destroyContext() }

    init(window: NSWindow?, panel: PrintProgressPanel = PrintProgressPanel()) {
        self.window = window
        self.panel = panel
        panel.onCancel = { [weak self] in self?.cancel() }
    }

    var isCancelled: Bool { run?.isCancelled ?? false }

    /// Sheet `index` of the spooled job: the run starts (and the panel shows) with the job's plan
    /// at its first sheet.  A cancelled job draws nothing more.
    func draw(sheet index: Int, of plan: PrintPlan, renderer: PrintSheetRenderer, into context: CGContext) throws {
        let run = run ?? start(plan, renderer: renderer)
        guard !run.isCancelled else { return endCancelled() }
        do {
            try run.draw(sheet: index, into: context)
        } catch is CancellationError {
            return endCancelled()
        }
        if run.sheetsDrawn >= run.count { finish() }
    }

    /// The first sheet after a cancel ends the job: nothing more reaches the printer.
    private func endCancelled() {
        guard !ended else { return }
        ended = true
        destroyContext()
        finish()
    }

    private func start(_ plan: PrintPlan, renderer: PrintSheetRenderer) -> PrintRun {
        let panel = panel
        let made = PrintRun(plan: plan, renderer: renderer) { progress in
            // Reported on the thread that draws: the main thread.
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { panel.update(progress) }
        }
        run = made
        panel.show(over: window)
        return made
    }

    /// btn:[Cancel].
    func cancel() {
        run?.cancel()
        panel.showCancelling()
    }

    /// The job ended (spooled, cancelled or failed): the snapshot goes and the panel closes.
    func finish() {
        run?.finish()
        panel.close()
    }
}

/// The progress panel of a print job: the sheet's label, a bar and btn:[Cancel], over the
/// document window.  AppKit controls, so a click reaches btn:[Cancel] through `pump()` while the
/// print loop holds the main thread.
@MainActor
final class PrintProgressPanel {
    let label = NSTextField(labelWithString: "Preparing to print…")
    let bar = NSProgressIndicator()
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private(set) var panel: NSPanel?
    var onCancel: @MainActor () -> Void = {}
    /// Whether `show` puts the panel on screen (tests keep it off).
    var showsWindow = true

    init() {
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.style = .bar
        label.setAccessibilityIdentifier("print.progress.label")
        bar.setAccessibilityIdentifier("print.progress.bar")
        cancelButton.setAccessibilityIdentifier("print.progress.cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
    }

    @objc private func cancelClicked() { onCancel() }

    var isShown: Bool { panel != nil }

    func show(over window: NSWindow?) {
        guard panel == nil else { return }
        let made = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 96), styleMask: [.titled, .utilityWindow], backing: .buffered, defer: true)
        made.title = "Printing"
        made.isReleasedWhenClosed = false
        made.identifier = NSUserInterfaceItemIdentifier("print-progress")
        let stack = NSStackView(views: [label, bar, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        bar.widthAnchor.constraint(equalToConstant: 328).isActive = true
        made.contentView = stack
        panel = made
        guard showsWindow else { return }
        if let frame = window?.frame {
            made.setFrameOrigin(NSPoint(x: frame.midX - 180, y: frame.maxY - 160))
        } else {
            made.center()
        }
        made.orderFront(nil)
    }

    /// Shows `progress`, redraws at once and handles what the user did meanwhile.
    func update(_ progress: PrintProgress) {
        label.stringValue = progress.label
        bar.doubleValue = progress.fraction
        panel?.displayIfNeeded()
        pump()
    }

    func showCancelling() {
        label.stringValue = "Cancelling…"
        cancelButton.isEnabled = false
        panel?.displayIfNeeded()
    }

    /// Delivers the clicks and keys queued for the panel (and kbd:[Esc] anywhere) while the print
    /// loop keeps the main thread; every other event goes back to the queue in order.
    func pump(events next: @MainActor () -> NSEvent? = {
        NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp], until: .distantPast, inMode: .default, dequeue: true)
    }, repost: @MainActor ([NSEvent]) -> Void = { events in for event in events.reversed() { NSApp.postEvent(event, atStart: true) } }) {
        var others: [NSEvent] = []
        while let event = next() {
            if event.type == .keyDown, event.keyCode == 53 {
                onCancel()
            } else if let panel, event.window === panel {
                NSApp.sendEvent(event)
            } else {
                others.append(event)
            }
        }
        repost(others)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
