import AppKit
import WTInterchange

// The *Embedded image profiles* preference at import (image-color.adoc, "Embedded profiles";
// CMS-012's app half): *Use embedded* and *Ignore* decide without asking; *Ask* shows a sheet naming
// the embedded profile and the document default, once per import, and its answer applies to every
// image of that import.  Files without an embedded profile never ask.

extension ImportController {
    /// What the embedded profiles of `scene` do: the preference, or -- for *Ask* -- the answer
    /// already given in this import (`answered`) or the sheet's.
    func embeddedProfilePolicy(for scene: ImportedScene, window: NSWindow?, answered: inout EmbeddedProfilePolicy?) async -> EmbeddedProfilePolicy {
        await embeddedProfilePolicy(for: scene.nodes + scene.layers.flatMap(\.nodes), window: window, answered: &answered)
    }

    /// What the embedded profiles of the images among `nodes` do (a file opened as a document).
    func embeddedProfilePolicy(for nodes: [ImportedNode], window: NSWindow?, answered: inout EmbeddedProfilePolicy?) async -> EmbeddedProfilePolicy {
        switch preferences[PreferenceCatalog.Import.embeddedProfiles] {
        case "ignore":
            return .ignore
        case "ask":
            guard let name = Self.embeddedProfileName(in: nodes) else { return .useEmbedded }
            if let answered { return answered }
            let answer = await askEmbeddedProfile(name, window)
            answered = answer
            return answer
        default:
            return .useEmbedded
        }
    }

    /// The name of the first embedded profile among `scene`'s images, nil when none carries one.
    static func embeddedProfileName(in scene: ImportedScene) -> String? {
        embeddedProfileName(in: scene.nodes + scene.layers.flatMap(\.nodes))
    }

    /// The name of the first embedded profile among the images of `nodes`.
    static func embeddedProfileName(in nodes: [ImportedNode]) -> String? {
        func find(_ nodes: [ImportedNode]) -> String? {
            for node in nodes {
                switch node {
                case .image(let image): if let profile = image.embeddedProfile { return profile.profile.name }
                case .group(let group): if let name = find(group.children) { return name }
                default: break
                }
            }
            return nil
        }
        return find(nodes)
    }
}

extension ModalUI {
    /// The *Ask* sheet: use the embedded profile, or read the images through the document default.
    static func embeddedProfile(_ name: String, on window: NSWindow?) async -> EmbeddedProfilePolicy {
        let alert = NSAlert()
        alert.messageText = "This image has an embedded color profile."
        alert.informativeText = "Read it through its embedded profile (\(name)), or through the document default? The profile is kept in the document either way."
        alert.addButton(withTitle: "Use Embedded")
        alert.addButton(withTitle: "Use Document Default")
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertSecondButtonReturn ? .ignore : .useEmbedded
    }
}
