import SwiftUI

/// SwiftUI's `List` on macOS is an `NSTableView`, and a table that goes from no rows to more than
/// about 200 in one update re-enters its own row-height cache while it sizes itself: AppKit logs
/// "Application performed a reentrant operation in its NSTableView delegate" and says the warning
/// will become an assert.  (Measured on macOS 26: 0 -> 250 rows warns, 0 -> 200 does not, and
/// 1 -> 300 or 50 -> 300 never does, whatever the rows' height, style, selection or the table's
/// size.)  A long list -- every command in the Keyboard Shortcuts and Customize Toolbars windows, a
/// document's swatches, a search cleared after matching nothing -- therefore shows its first
/// `firstRows` rows in the update that fills it and the rest in the next (`GrowingRows`).
///
/// A run of row moves (rows identified by object, reordered several times) warns the same way even
/// in a short list; Reading Order identifies its rows by position instead.  The test host counts
/// the warning and names the list behind it (WTAppTests/Support/TableReentrancy.c,
/// TableReentrancyTests).
enum ListRowGrowth {
    /// The most rows a list shows in the update after it showed none.
    static let firstRows = 100

    /// How many of `count` rows to show when `shown` were shown in the last update.
    static func limit(count: Int, shown: Int) -> Int {
        shown == 0 ? min(count, firstRows) : count
    }

    /// The first `limit` rows of sectioned `groups` (a group past the limit drops out, the one it
    /// falls in keeps its first rows).
    static func prefix<Group, Row>(_ groups: [Group], limit: Int, rows: (Group) -> [Row], with make: (Group, [Row]) -> Group) -> [Group] {
        var left = limit
        var result: [Group] = []
        for group in groups {
            guard left > 0 else { break }
            let all = rows(group)
            if all.count <= left {
                result.append(group)
            } else {
                result.append(make(group, Array(all.prefix(left))))
            }
            left -= min(all.count, left)
        }
        return result
    }
}

/// `content` given how many of its `count` rows to show: at most `ListRowGrowth.firstRows` in the
/// update after it showed none, then all of them.
struct GrowingRows<Content: View>: View {
    let count: Int
    @ViewBuilder let content: (_ limit: Int) -> Content
    @State private var shown = 0

    var body: some View {
        let limit = ListRowGrowth.limit(count: count, shown: shown)
        content(limit)
            .onChange(of: limit, initial: true) { _, limit in shown = limit }
    }
}
