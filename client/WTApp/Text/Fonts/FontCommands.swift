import AppKit
import WTCRDT
import WTModel
import WTProto
import WTText

/// What the font controls read off the selection: the Text tool's selection (its pending format
/// at an insertion point), else every selected block whole.  Each value is nil when the text
/// differs, and the sets say which values the text holds (the menus mark each of them as mixed).
extension ObjectPanelModel {
    /// The runs the font controls read.
    var fontRuns: [[Wiretuner_Doc_V1_TextMarkValue]] {
        let runs = editingText?.formatRuns ?? targetRuns
        return runs.isEmpty ? [[]] : runs
    }

    /// The families, faces and sizes the targeted text holds.
    var fontFamilies: Set<String> { Set(fontRuns.map(Self.family)) }
    var fontStyles: Set<String> { Set(fontRuns.map(Self.style)) }
    var fontSizes: Set<Double> { Set(fontRuns.map(Self.size)) }

    /// A family and face in one change, labelled "Font" (the *Other…* sheet).
    @discardableResult
    func setFont(family: String, style: String?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard !family.isEmpty else { return nil }
        guard let style, !style.isEmpty else { return setFontFamily(family) }
        return formatText([.with { $0.fontFamily = family }, .with { $0.fontStyle = style }], label: "Font")
    }

    /// *Smaller* and *Larger* on whole blocks: every run's size moved by `delta` (kept to
    /// 1--10,000 points), one change labelled "Size".  The Text tool's selection goes through its
    /// nudger instead, so the keys add up as they do while typing (TYPE-019).
    @discardableResult
    func stepFontSize(by delta: Double) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard editingText == nil, let section = text else { return nil }
        let state = document.state
        var commands: [any WTModel.Command] = []
        for node in section.nodes {
            guard let text = state.textNode(node) else { continue }
            for run in text.runs {
                let size = TypeSizes.stepped(Self.size(run.values), by: delta)
                commands.append(ApplyMark(node: node, from: text.anchor(at: run.range.lowerBound), to: text.anchor(at: run.range.upperBound),
                                          value: Self.sizeMark(size), label: "Size"))
            }
        }
        return commands.isEmpty ? nil : perform(CommandBatch("Size", commands))
    }

    static func sizeMark(_ size: Double) -> Wiretuner_Doc_V1_TextMarkValue {
        .with { $0.size = size }
    }
}

/// The recently used families, most recent first, kept in the user defaults (they are yours,
/// like the menus' other state).
@MainActor
final class FontRecentsStore {
    static let key = "text.recent_font_families"
    static let shared = FontRecentsStore()

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var families: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    func note(_ family: String) {
        defaults.set(FontRecents.adding(family, to: families), forKey: Self.key)
    }
}

/// menu:Text[Font] and menu:Text[Size], the same submenus of the text context menus, and the
/// Text toolbar's font family, style and size (type-specifications.adoc, "Font, size and style";
/// type-tools.adoc; the font and size part of TYPE-017).  Every application is one change,
/// labelled "Font", "Font Style" or "Size".  The family and face lists are read when their menu
/// opens (`FontMenus`); the sizes are commands.
@MainActor
enum FontCommands {
    typealias Window = @MainActor () -> DocumentWindowController?

    enum ID {
        static let fontOther = ContextMenuCatalog.ID.fontOther
        static func size(_ points: Int) -> CommandID { ContextMenuCatalog.ID.size(points) }
        static let smaller = ContextMenuCatalog.ID.sizeSmaller
        static let larger = ContextMenuCatalog.ID.sizeLarger
        static let sizeOther = ContextMenuCatalog.ID.sizeOther
        static let family: CommandID = "text.fontFamily"
        static let style: CommandID = "text.fontStyle"
        static let fontSize: CommandID = "text.fontSize"
    }

    static let noText = TextFeatures.noText
    static let fontMenu = "Font"
    static let sizeMenu = "Size"
    static let styleMenu = "Style"
    static let contexts: Set<MenuContext> = [.text, .textEditing]
    static let smallerKey = KeyEquivalent(",", [.command, .shift])
    static let largerKey = KeyEquivalent(".", [.command, .shift])

    /// The Object panel model of `window`'s selection when it is text.
    static func model(_ window: DocumentWindowController?) -> ObjectPanelModel? {
        guard let model = TextFeatures.model(window), model.text != nil else { return nil }
        return model
    }

    static func hasText(_ window: @escaping Window) -> @MainActor @Sendable () -> CommandValidation {
        { model(window()) == nil ? .disabled(noText) : .enabled }
    }

    // MARK: Applying

    /// A family from a menu or the toolbar; remembered among the recent ones.
    @discardableResult
    static func apply(family: String, window: DocumentWindowController?, recents: FontRecentsStore = .shared) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let task = model(window)?.setFontFamily(family) else { return nil }
        recents.note(family)
        return task
    }

    /// A face of the text's family (the Style menu's other faces, the toolbar's Style pop-up).
    @discardableResult
    static func apply(style: String, window: DocumentWindowController?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard !style.isEmpty else { return nil }
        return model(window)?.setFontStyleNamed(style)
    }

    /// A family and face together (the *Other…* sheet).
    @discardableResult
    static func apply(family: String, style: String?, window: DocumentWindowController?, recents: FontRecentsStore = .shared) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let task = model(window)?.setFont(family: family, style: style) else { return nil }
        recents.note(family)
        return task
    }

    /// A size (a preset, the toolbar's field, the *Other…* sheet), 1--10,000 points.
    @discardableResult
    static func apply(size: Double, window: DocumentWindowController?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard TypeSizes.range.contains(size) else { return nil }
        return model(window)?.setFontSize(size)
    }

    /// *Smaller* (-1) and *Larger* (+1).  While the Text tool edits, the nudger adds the steps up
    /// and writes them once a second passes (nil here); otherwise one change now.
    @discardableResult
    static func step(_ delta: Double, window: DocumentWindowController?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let window, let model = model(window) else { return nil }
        if model.editingText != nil {
            TypeNudger.nudger(for: window.objectEditing).nudge(TypeNudge(kind: .size, delta: delta))
            return nil
        }
        return model.stepFontSize(by: delta)
    }

    // MARK: Commands

    static func commands(window: @escaping Window, sheets: FontSheets = .shared) -> [Command] {
        let text = ContextMenuCatalog.Menu.text
        let hasText = hasText(window)
        var result = TypeSizes.presets.map { points in
            Command(id: ID.size(Int(points)), title: "\(TypeSizes.format(points)) pt", menu: MenuPath(text, sizeMenu, section: 1), contexts: contexts,
                    keywords: ["size", "type size", "points"],
                    validation: {
                        guard let model = model(window()) else { return .disabled(noText) }
                        return .checked(model.fontSizes == [points])
                    },
                    action: .perform { apply(size: points, window: window()) })
        }
        result.append(Command(id: ID.smaller, title: "Smaller", key: smallerKey, menu: MenuPath(text, sizeMenu, section: 1, subsection: 1), contexts: contexts,
                              keywords: ["size", "decrease", "type size"],
                              validation: {
                                  guard let model = model(window()) else { return .disabled(noText) }
                                  return model.fontSizes.allSatisfy { $0 <= TypeSizes.range.lowerBound } ? .disabled("The text is at the smallest size") : .enabled
                              },
                              action: .perform { step(-TypeSizes.step, window: window()) }))
        result.append(Command(id: ID.larger, title: "Larger", key: largerKey, menu: MenuPath(text, sizeMenu, section: 1, subsection: 1), contexts: contexts,
                              keywords: ["size", "increase", "type size"],
                              validation: {
                                  guard let model = model(window()) else { return .disabled(noText) }
                                  return model.fontSizes.allSatisfy { $0 >= TypeSizes.range.upperBound } ? .disabled("The text is at the largest size") : .enabled
                              },
                              action: .perform { step(TypeSizes.step, window: window()) }))
        result.append(Command(id: ID.sizeOther, title: "Other…", menu: MenuPath(text, sizeMenu, section: 1, subsection: 1), contexts: contexts,
                              keywords: ["size", "type size", "points"],
                              validation: {
                                  guard let model = model(window()) else { return .disabled(noText) }
                                  let sizes = model.fontSizes
                                  // Checked, with the size, when the text shares one that is not a preset.
                                  if sizes.count == 1, let size = sizes.first, !TypeSizes.presets.contains(size) {
                                      return CommandValidation(isChecked: true, title: "Other (\(TypeSizes.format(size)) pt)…")
                                  }
                                  return .enabled
                              },
                              action: .perform { if let front = window() { sheets.showSize(on: front) } }))
        result.append(Command(id: ID.fontOther, title: "Other…", menu: MenuPath(text, fontMenu, section: 1, subsection: 3), contexts: contexts,
                              keywords: ["font", "family", "typeface"], validation: hasText,
                              action: .perform { if let front = window() { sheets.showFont(on: front) } }))
        // The Text toolbar's three controls; from the palette (or a button) they open the sheets.
        result.append(Command(id: ID.family, title: "Font Family", keywords: ["toolbar", "text", "font"], validation: hasText,
                              action: .perform { if let front = window() { sheets.showFont(on: front) } }))
        result.append(Command(id: ID.style, title: "Font Style", keywords: ["toolbar", "text", "face"], validation: hasText,
                              action: .perform { if let front = window() { sheets.showFont(on: front) } }))
        result.append(Command(id: ID.fontSize, title: "Font Size", keywords: ["toolbar", "text", "size"], validation: hasText,
                              action: .perform { if let front = window() { sheets.showSize(on: front) } }))
        return result
    }
}

extension AppDelegate {
    /// menu:Text[Font] and menu:Text[Size], their context-menu twins and the Text toolbar's font
    /// controls: the size and sheet commands to register, the menus' delegate and the toolbar's
    /// controls.
    func installFontControls(window: @escaping FontCommands.Window) -> [Command] {
        FontMenus.shared.window = window
        MainMenuBuilder.dynamicMenus = { FontMenus.delegate(for: $0) }
        toolbars.controller.controls = FontToolbarControls.makers(window: window)
        return FontCommands.commands(window: window)
    }
}
