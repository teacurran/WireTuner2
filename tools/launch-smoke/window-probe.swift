// Counts the document windows a process has on screen, for launch-smoke.sh.  Uses only
// CGWindowListCopyWindowInfo's owner, layer, bounds and on-screen keys, which need neither
// Screen Recording nor Accessibility permission (window titles, which do, are not read).
//
// Usage: window-probe <pid>     prints "<count> <width>x<height> ..." for the pid's windows
//                                on the normal window layer at least 300 x 200 points.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-probe <pid>\n".utf8))
    exit(2)
}
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
let documents = windows.filter { window in
    guard (window[kCGWindowOwnerPID as String] as? Int32) == pid, (window[kCGWindowLayer as String] as? Int) == 0,
          let bounds = window[kCGWindowBounds as String] as? [String: Double] else { return false }
    return (bounds["Width"] ?? 0) >= 300 && (bounds["Height"] ?? 0) >= 200
}
let sizes = documents.compactMap { $0[kCGWindowBounds as String] as? [String: Double] }.map { "\(Int($0["Width"] ?? 0))x\(Int($0["Height"] ?? 0))" }
print(([String(documents.count)] + sizes).joined(separator: " "))
