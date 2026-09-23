import XCTest

/// Asserts that the app opened no sockets while a block ran (TEST-002): the on-device ML and
/// scripting tasks use it to show a feature never reaches the network.
///
/// The app audits itself.  Launched with `-WTSocketAudit` (a DEBUG build; `WireTunerUI.launch`
/// always passes it), its `SocketMonitor` samples the process's descriptors every 5 ms and the
/// canvas's accessibility value gains `net=<n> unix=<n>`: the distinct internet and
/// Unix-domain sockets the process has had open since launch.  The audit reads the counts before
/// and after the block; any growth fails the test.  Auditing from the runner with `lsof` was the
/// first choice (no code in the app, and it would see the release build), but Xcode signs the
/// XCUITest runner with the App Sandbox, which cannot inspect another process; see testing.adoc,
/// "UI".
@MainActor
enum SandboxAudit {
    /// How long to let the monitor take its last samples (many intervals).
    static let settle: TimeInterval = 0.25

    struct Counts: Equatable, CustomStringConvertible {
        var internet: Int
        var unixDomain: Int
        var description: String { "net=\(internet) unix=\(unixDomain)" }
    }

    /// The counts in a parsed canvas state, nil when the app was launched without the audit.
    nonisolated static func counts(in state: [String: Int]) -> Counts? {
        guard let internet = state["net"], let unixDomain = state["unix"] else { return nil }
        return Counts(internet: internet, unixDomain: unixDomain)
    }

    /// Which growth fails the audit: internet sockets always; Unix-domain sockets when
    /// `includeUnixDomain` (system frameworks may open those on their own).
    nonisolated static func violations(before: Counts, after: Counts, includeUnixDomain: Bool) -> [String] {
        var result: [String] = []
        if after.internet > before.internet { result.append("\(after.internet - before.internet) internet socket(s)") }
        if includeUnixDomain, after.unixDomain > before.unixDomain { result.append("\(after.unixDomain - before.unixDomain) Unix-domain socket(s)") }
        return result
    }

    /// Runs `block` and fails the test if the app opened a socket meanwhile.
    static func assertNoSockets(
        in ui: WireTunerUI, includeUnixDomain: Bool = false, file: StaticString = #filePath, line: UInt = #line,
        during block: () throws -> Void
    ) rethrows {
        guard let before = counts(in: ui.canvasState) else {
            XCTFail("the app was launched without \(WireTunerUI.socketAuditArgument)", file: file, line: line)
            return
        }
        try block()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        guard let after = counts(in: ui.canvasState) else {
            XCTFail("the canvas stopped reporting socket counts", file: file, line: line)
            return
        }
        let violations = violations(before: before, after: after, includeUnixDomain: includeUnixDomain)
        XCTAssertTrue(violations.isEmpty, "the app opened \(violations.joined(separator: " and ")) (\(before) → \(after))", file: file, line: line)
    }
}
