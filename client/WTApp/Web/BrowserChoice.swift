import AppKit
import SwiftUI

/// The browser pop-up of the Publish sheet's *Open when done* (WEB-009; publish-html.adoc,
/// "Publishing"): the default browser, every browser installed, and btn:[Other…] to pick an
/// application.  The choice is the *Preview browser* preference (this Mac's), so
/// menu:View[Preview in Browser] opens the same one.
enum BrowserChoice: Hashable {
    /// The system's default browser (the preference empty).
    case system
    case application(URL)
    /// btn:[Other…]: an open panel for any application.
    case other
}

/// The browsers on this Mac, read from Launch Services.
@MainActor
struct BrowserList {
    /// A web address every browser opens: an `.html` file's list holds text editors too.
    static let probe = URL(string: "https://example.com/")!

    /// The applications that open web links, the default first, then by name.
    var installed: @MainActor () -> [URL] = {
        let workspace = NSWorkspace.shared
        let all = workspace.urlsForApplications(toOpen: BrowserList.probe)
        let preferred = workspace.urlForApplication(toOpen: BrowserList.probe)
        return BrowserList.ordered(all, default: preferred)
    }
    /// The default browser.
    var defaultBrowser: @MainActor () -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: BrowserList.probe) }

    nonisolated init() {}

    /// `urls` without duplicates, `preferred` first, the rest by display name.
    nonisolated static func ordered(_ urls: [URL], default preferred: URL?) -> [URL] {
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let rest = unique.filter { $0.standardizedFileURL.path != preferred?.standardizedFileURL.path }
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        guard let preferred, unique.contains(where: { $0.standardizedFileURL.path == preferred.standardizedFileURL.path }) else { return rest }
        return [preferred] + rest
    }

    /// "Safari" for `/Applications/Safari.app`.
    nonisolated static func name(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// The pop-up itself.
struct BrowserPicker: View {
    let choices: [URL]
    let defaultName: String?
    let selection: Binding<BrowserChoice>

    var body: some View {
        Picker("Browser", selection: selection) {
            Text(defaultName.map { "Default Browser (\($0))" } ?? "Default Browser").tag(BrowserChoice.system)
            Divider()
            ForEach(choices, id: \.self) { Text(BrowserList.name($0)).tag(BrowserChoice.application($0)) }
            Divider()
            Text("Other…").tag(BrowserChoice.other)
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("publish.browser")
    }
}
