import AppKit
import PDFKit

/// How commands are grouped in the Keyboard Shortcuts window, on the quick-reference card and
/// in the CSV: by top-level menu, in menu-bar order, with the commands that have no menu item
/// under *Tools/Commands* at the end (customizing.adoc, "Assigning a shortcut").
enum ShortcutCategories {
    static let menuless = "Tools/Commands"

    static func category(of command: Command) -> String {
        command.menuPath?.menu ?? menuless
    }

    /// The command's place below its top-level menu and its title: "Magnification > 100%".
    static func qualifiedTitle(of command: Command) -> String {
        let path = command.menuPath.map { Array($0.components.dropFirst()) } ?? []
        return (path + [command.title]).joined(separator: " > ")
    }

    /// The menu path to show as a description: "View > Magnification", or *Tools/Commands*.
    static func location(of command: Command) -> String {
        command.menuPath.map { $0.components.joined(separator: " > ") } ?? menuless
    }

    /// Category titles in display order for `commands`.
    static func orderedCategories(_ commands: [Command]) -> [String] {
        var seen: [String] = []
        for command in commands where command.menuPath != nil {
            let title = category(of: command)
            if !seen.contains(title) { seen.append(title) }
        }
        let menus = MenuTreeBuilder.orderedMenuTitles(seen, preferring: MenuTreeBuilder.standardMenuOrder)
        return commands.contains { $0.menuPath == nil } ? menus + [menuless] : menus
    }

    /// `commands` grouped by category, in display order.
    static func grouped(_ commands: [Command]) -> [(title: String, commands: [Command])] {
        let byCategory = Dictionary(grouping: commands, by: category(of:))
        return orderedCategories(commands).map { ($0, byCategory[$0, default: []]) }
    }

    /// Several keys as the card and the window show them: "⌘1, ⌥⌘1".
    static func display(_ keys: [KeyEquivalent]) -> String {
        keys.map(\.displayString).joined(separator: ", ")
    }
}

/// The quick-reference card's content: one section per menu.
struct ShortcutCardSection: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let title: String
        let shortcut: String
    }

    let title: String
    let entries: [Entry]

    static func sections(commands: [Command], set: ShortcutSet, includeUnbound: Bool) -> [ShortcutCardSection] {
        ShortcutCategories.grouped(commands).compactMap { group in
            let entries = group.commands.compactMap { command -> Entry? in
                let keys = set.keys(for: command.id)
                guard includeUnbound || !keys.isEmpty else { return nil }
                return Entry(title: ShortcutCategories.qualifiedTitle(of: command), shortcut: ShortcutCategories.display(keys))
            }
            return entries.isEmpty ? nil : ShortcutCardSection(title: group.title, entries: entries)
        }
    }
}

/// Where each line of the card goes: US Letter pages, two columns, a section header never left
/// alone at the bottom of a column.  Pure, so pagination is tested without drawing.
struct ShortcutCardLayout: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case title
        case header
        case entry(shortcut: String)
    }

    struct Line: Equatable, Sendable {
        let page: Int
        let origin: CGPoint
        let width: CGFloat
        let text: String
        let kind: Kind
    }

    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 36
    static let columns = 2
    static let columnGap: CGFloat = 24
    static let titleHeight: CGFloat = 28
    static let headerHeight: CGFloat = 20
    static let entryHeight: CGFloat = 13

    let lines: [Line]
    let pageCount: Int

    static var columnWidth: CGFloat {
        (pageSize.width - 2 * margin - CGFloat(columns - 1) * columnGap) / CGFloat(columns)
    }

    init(title: String, sections: [ShortcutCardSection]) {
        var lines = [Line(page: 0, origin: CGPoint(x: Self.margin, y: Self.margin), width: Self.pageSize.width - 2 * Self.margin, text: title, kind: .title)]
        var page = 0, column = 0
        var y = Self.margin + Self.titleHeight
        let bottom = Self.pageSize.height - Self.margin
        func advance() {
            column += 1
            if column == Self.columns {
                column = 0
                page += 1
            }
            y = Self.margin
        }
        func place(_ text: String, _ kind: Kind, height: CGFloat, needs: CGFloat) {
            if y + needs > bottom { advance() }
            let x = Self.margin + CGFloat(column) * (Self.columnWidth + Self.columnGap)
            lines.append(Line(page: page, origin: CGPoint(x: x, y: y), width: Self.columnWidth, text: text, kind: kind))
            y += height
        }
        for section in sections {
            place(section.title, .header, height: Self.headerHeight, needs: Self.headerHeight + Self.entryHeight)
            for entry in section.entries {
                place(entry.title, .entry(shortcut: entry.shortcut), height: Self.entryHeight, needs: Self.entryHeight)
            }
        }
        self.lines = lines
        pageCount = page + 1
    }

    func lines(onPage page: Int) -> [Line] { lines.filter { $0.page == page } }
}

/// The card as a paginated view: `NSPrintOperation` prints it and *Save as PDF* writes the same
/// pages.  Flipped, one page below the other.
@MainActor
final class ShortcutCardView: NSView {
    let layout: ShortcutCardLayout

    init(layout: ShortcutCardLayout) {
        self.layout = layout
        let size = ShortcutCardLayout.pageSize
        super.init(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height * CGFloat(layout.pageCount)))
    }

    convenience init(title: String, commands: [Command], set: ShortcutSet, includeUnbound: Bool) {
        self.init(layout: ShortcutCardLayout(title: title, sections: ShortcutCardSection.sections(commands: commands, set: set, includeUnbound: includeUnbound)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShortcutCardView is built in code")
    }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: layout.pageCount)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let size = ShortcutCardLayout.pageSize
        return NSRect(x: 0, y: size.height * CGFloat(page - 1), width: size.width, height: size.height)
    }

    static let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.black]
    static let headerAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.black]
    static let entryAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black]

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        let pageHeight = ShortcutCardLayout.pageSize.height
        for line in layout.lines {
            let origin = CGPoint(x: line.origin.x, y: line.origin.y + pageHeight * CGFloat(line.page))
            let rect = NSRect(origin: origin, size: CGSize(width: line.width, height: ShortcutCardLayout.headerHeight))
            guard rect.intersects(dirtyRect) else { continue }
            switch line.kind {
            case .title:
                (line.text as NSString).draw(in: rect.insetBy(dx: 0, dy: -4), withAttributes: Self.titleAttributes)
            case .header:
                (line.text as NSString).draw(in: rect, withAttributes: Self.headerAttributes)
            case let .entry(shortcut):
                let shortcutWidth: CGFloat = 70
                (line.text as NSString).draw(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width - shortcutWidth, height: ShortcutCardLayout.entryHeight), withAttributes: Self.entryAttributes)
                (shortcut as NSString).draw(in: NSRect(x: rect.maxX - shortcutWidth, y: rect.minY, width: shortcutWidth, height: ShortcutCardLayout.entryHeight), withAttributes: Self.entryAttributes)
            }
        }
    }

    /// Print settings for the card: US Letter, no margins (the layout has its own).
    static func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = ShortcutCardLayout.pageSize
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .automatic
        return info
    }

    /// The card as a multi-page PDF (*Save as PDF*): each page's rectangle through
    /// `dataWithPDF(inside:)`, joined into one document.
    func pdfData() -> Data {
        let document = PDFDocument()
        for page in 1...layout.pageCount {
            if let single = PDFDocument(data: dataWithPDF(inside: rectForPage(page)))?.page(at: 0) {
                document.insert(single, at: document.pageCount)
            }
        }
        return document.dataRepresentation() ?? Data()
    }

    /// The system print dialog (with its own preview) for the card.
    func printOperation() -> NSPrintOperation {
        let operation = NSPrintOperation(view: self, printInfo: Self.printInfo())
        operation.jobTitle = "Keyboard Shortcuts"
        return operation
    }
}

/// menu:Edit[Keyboard Shortcuts…] > ⋯ > *Export as Text…*: RFC 4180 CSV, one row per binding
/// (command, shortcut, description), CRLF line ends, a header row.
enum ShortcutCSV {
    static let header = ["command", "shortcut", "description"]

    static func export(set: ShortcutSet, commands: [Command]) -> String {
        let byID = Dictionary(grouping: commands, by: \.id)
        var rows = [header]
        for binding in set.bindings {
            let command = byID[binding.commandID]?.first
            rows.append([
                command.map(ShortcutCategories.qualifiedTitle(of:)) ?? binding.commandID.rawValue,
                binding.keys.map(\.canonical).joined(separator: " "),
                command.map(ShortcutCategories.location(of:)) ?? "",
            ])
        }
        return rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// A field, quoted when it holds a comma, a quote or a line break; quotes doubled.
    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
