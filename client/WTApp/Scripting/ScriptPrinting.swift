import AppKit
import WTInterchange
import WTModel

/// `print document 1 print preset "Press proof"` and *Print Document*'s preset (scripting.adoc,
/// "Print with a named print preset"; DOC-026, DOC-027).  The presets are the Print dialog's own
/// (printing.adoc, "Presets are stored on your Mac"): the panel saves them, with the `WTPrint*`
/// settings the session writes into the print info, in the `com.apple.print.custompresets`
/// preferences -- one domain per printer and a general one.  Printing with one writes its
/// {product} settings to the document as one change ("Script: apply print preset" or "Shortcut:
/// …"), then opens menu:File[Print…] once that change is applied.
@MainActor
enum ScriptPrinting {
    static let domain = "com.apple.print.custompresets"
    static let settingsKey = "com.apple.print.preset.settings"
    static let idKey = "com.apple.print.preset.id"

    /// The preset domains to look in, the printer's first: `…forprinter.<name>` with every
    /// character but letters and digits written `_`, as the print system names it.
    static func domains(printer: String?) -> [String] {
        guard let printer, !printer.isEmpty else { return [domain] }
        let name = String(printer.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_" })
        return ["\(domain).forprinter.\(name)", domain]
    }

    /// The saved settings of the preset named `name` (its key or its `preset.id`), searching
    /// `domains` in order; nil when no domain has it.
    static func settings(named name: String, in domains: [[String: Any]]) -> [String: Any]? {
        for domain in domains {
            let preset = (domain[name] as? [String: Any])
                ?? domain.values.compactMap { $0 as? [String: Any] }.first { $0[idKey] as? String == name }
            if let settings = preset?[settingsKey] as? [String: Any] { return settings }
        }
        return nil
    }

    /// The saved settings of `name` in this Mac's preset domains.
    static var lookup: @MainActor (String) -> [String: Any]? = { name in
        let printer = NSPrintInfo.shared.printer.name
        return settings(named: name, in: domains(printer: printer).compactMap { UserDefaults.standard.persistentDomain(forName: $0) })
    }

    /// Prints `handle` with the preset `name`: its {product} settings (when it has any that differ
    /// from the document's) as one change labelled `label`, then `show` (menu:File[Print…]) once
    /// it is applied.  Returns the reason it cannot, or nil.
    static func print(_ handle: DocumentHandle, preset name: String, label: String,
                      show: @escaping @MainActor () -> String?) -> String? {
        guard let settings = lookup(name) else { return "No print preset is named “\(name)” on this Mac" }
        let current = PrintPresets.preset(handle.state)
        guard let loaded = PrintPreset.read(settings), loaded.preset != current.preset || loaded.includeHiddenLayers != current.includeHiddenLayers else {
            // A preset saved from another application (or matching the document) sets only the
            // panel's own settings.
            return show()
        }
        let role = ScriptingHost.shared.role(handle)
        guard role == nil || role == .owner || role == .editor else { return "Printing with “\(name)” changes the print settings, which needs the editor role" }
        let task = handle.perform(ScriptLabelled(ApplyPrintPreset(loaded.preset, includeHiddenLayers: loaded.includeHiddenLayers), label: label))
        Task { @MainActor in
            _ = await task.value
            _ = show()
        }
        return nil
    }
}
