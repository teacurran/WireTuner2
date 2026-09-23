// The client's timing budgets (docs/spec/testing.adoc, "Where budgets run").
//
// One file, shared by symbolic link: every test target that holds a budget has
// `Support/PerfBudget.swift` pointing here (client/Packages/WTTestSupport/Shared), so the rule is
// written once without a package dependency.  A product of the WTTestSupport package would not
// do: that package depends on every other package, so WTGeometry's tests depending on it would
// make SwiftPM resolve gRPC, NIO and GRDB for WTGeometry, WTRender and WTText, which have no
// remote dependencies today.  The linked copies compile into each test module as internal code
// under the module's own build configuration, which is what `isReleaseBuild` reads.

import Foundation
import Testing

/// Holds a measured duration to its budget -- only in a perf run.
///
/// A test that times something asserts two things: that the work is right, and that it was fast
/// enough.  The first runs in every build, as ordinary `#expect`s.  The second goes through
/// `PerfBudget.expect`, which holds the figure to its budget only when all of these are true:
///
/// * `WT_PERF=1` is in the environment (`make client-perf` sets it);
/// * the test module is a release build (`swift test -c release -Xswiftc -enable-testing`), or
///   the call says why a debug figure is meaningful (`enforcedInDebug:`);
/// * the one-minute load average is at most 1.5 times the active cores
///   (`WT_PERF_LOAD_FACTOR` changes the factor; `0` turns the guard off).
///
/// Otherwise the budget is not checked.  In a perf run every call also appends a row -- measure,
/// measured, budget, build, and met, missed or why it was skipped -- to
/// `client/build/perf-results.md` (`WT_PERF_RESULTS` names another file) and prints it prefixed
/// `PERF `, so a run whose process cannot write there (the sandboxed app's tests) still reports.
enum PerfBudget {
    /// The load factor when `WT_PERF_LOAD_FACTOR` is unset: busier than this, a figure says more
    /// about the machine than about the code.
    static let defaultLoadFactor = 1.5

    static let header = "| Measure | Measured | Budget | Build | Result |\n|---|---|---|---|---|\n"

    #if DEBUG
    static let isReleaseBuild = false
    #else
    static let isReleaseBuild = true
    #endif

    /// `WT_PERF=1`: this is a perf run.
    static var isRequested: Bool {
        isRequested(ProcessInfo.processInfo.environment)
    }

    /// A perf run of a release build: where a scenario whose volume is only there for timing
    /// uses its full volume.  Correctness runs use the smaller one.
    static var isMeasuring: Bool {
        isRequested && isReleaseBuild
    }

    /// Holds `measured` to at most `budget` in a perf run; does nothing otherwise.
    ///
    /// - Parameters:
    ///   - detail: appended to the measure's name (the case of a parameterised test, the slowest
    ///     input of a fuzz run).
    ///   - enforcedInDebug: why a debug build's figure is meaningful for this budget; without it
    ///     the budget is held in release builds only.
    ///   - knownIssue: a budget known to be missed on current hardware: a miss is recorded as a
    ///     known issue, with this text, and reported, instead of failing the test.
    static func expect(
        _ measured: Duration,
        within budget: Duration,
        _ detail: String? = nil,
        enforcedInDebug: String? = nil,
        knownIssue: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        check(
            measured, within: budget, detail, enforcedInDebug: enforcedInDebug, knownIssue: knownIssue,
            environment: ProcessInfo.processInfo.environment, isReleaseBuild: isReleaseBuild,
            load: loadAverage(), cores: ProcessInfo.processInfo.activeProcessorCount, sourceLocation: sourceLocation
        )
    }

    /// `expect` with its surroundings given; returns the row reported, if any.
    @discardableResult
    static func check(
        _ measured: Duration,
        within budget: Duration,
        _ detail: String?,
        enforcedInDebug: String?,
        knownIssue: String?,
        environment: [String: String],
        isReleaseBuild: Bool,
        load: Double?,
        cores: Int,
        sourceLocation: SourceLocation
    ) -> Row? {
        let decision = decide(environment: environment, isReleaseBuild: isReleaseBuild, debugReason: enforcedInDebug, load: load, cores: cores)
        let measure = measureName(detail)
        let build = isReleaseBuild ? "release" : "debug"
        let row: Row
        switch decision {
        case .notRequested:
            return nil
        case .skipped(let reason):
            row = Row(measure: measure, measured: format(measured), budget: format(budget), build: build, result: "skipped: \(reason)")
        case .enforced:
            let met = measured <= budget
            let result = met ? "met" : (knownIssue.map { "**missed** (known issue: \($0))" } ?? "**missed**")
            row = Row(measure: measure, measured: format(measured), budget: format(budget), build: build, result: result)
            if !met {
                let comment = Comment(rawValue: "\(measure): \(format(measured)) is over the \(format(budget)) budget")
                if let knownIssue {
                    withKnownIssue(Comment(rawValue: knownIssue), isIntermittent: true) {
                        Issue.record(comment, sourceLocation: sourceLocation)
                    }
                } else {
                    Issue.record(comment, sourceLocation: sourceLocation)
                }
            }
        }
        report(row, environment: environment)
        return row
    }

    /// Reports a figure that has no budget (a peak memory size, say) in a perf run.
    static func record(_ figure: String, _ detail: String? = nil) {
        let environment = ProcessInfo.processInfo.environment
        guard isRequested(environment) else {
            return
        }
        report(Row(measure: measureName(detail), measured: figure, budget: "-", build: buildName, result: "reported"), environment: environment)
    }

    // MARK: The rule

    enum Decision: Equatable {
        /// Not a perf run: nothing is checked or written.
        case notRequested
        /// A perf run in which this budget cannot be judged, and why.
        case skipped(String)
        case enforced
    }

    static func isRequested(_ environment: [String: String]) -> Bool {
        environment["WT_PERF"] == "1"
    }

    /// Whether a budget is held, given the environment, the build, the one-minute load average
    /// (nil when it cannot be read) and the active cores.
    static func decide(environment: [String: String], isReleaseBuild: Bool, debugReason: String?, load: Double?, cores: Int) -> Decision {
        guard isRequested(environment) else {
            return .notRequested
        }
        guard isReleaseBuild || debugReason != nil else {
            return .skipped("debug build; the budget is held in release builds (make client-perf)")
        }
        let factor = environment["WT_PERF_LOAD_FACTOR"].flatMap(Double.init) ?? defaultLoadFactor
        let limit = Double(cores) * factor
        if factor > 0, let load, load > limit {
            return .skipped(String(format: "load %.1f over %.1f (%d cores x %@)", load, limit, cores, "\(factor)"))
        }
        return .enforced
    }

    /// The one-minute load average, or nil when the system does not say.
    static func loadAverage() -> Double? {
        var loads = [0.0]
        return getloadavg(&loads, 1) == 1 ? loads[0] : nil
    }

    // MARK: The report

    struct Row: Equatable {
        var measure: String
        var measured: String
        var budget: String
        var build: String
        var result: String

        var markdown: String {
            "| \(measure) | \(measured) | \(budget) | \(build) | \(result) |"
        }
    }

    static var buildName: String {
        isReleaseBuild ? "release" : "debug"
    }

    /// `WTGeometry/PerformanceTests.boundsInATightLoop`, from the running test, plus `detail`.
    static func measureName(_ detail: String?) -> String {
        let name = Test.current.map { measureName(module: $0.id.moduleName, components: $0.id.nameComponents) } ?? "(no test)"
        guard let detail, !detail.isEmpty else {
            return name
        }
        return "\(name) [\(detail)]"
    }

    static func measureName(module: String, components: [String]) -> String {
        let package = module.hasSuffix("Tests") ? String(module.dropLast(5)) : module
        let path = components.map { component -> String in
            guard let parenthesis = component.firstIndex(of: "(") else {
                return component
            }
            return String(component[..<parenthesis])
        }
        return "\(package)/\(path.joined(separator: "."))"
    }

    /// `850 µs`, `12.3 ms`, `2.41 s`.
    static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if abs(seconds) >= 1 {
            return String(format: "%.2f s", seconds)
        }
        if abs(seconds) >= 1e-3 {
            return String(format: "%.1f ms", seconds * 1e3)
        }
        return String(format: "%.0f µs", seconds * 1e6)
    }

    /// Where the table goes: `WT_PERF_RESULTS`, else `client/build/perf-results.md` above the
    /// test sources this file was compiled into.
    static func resultsURL(environment: [String: String], sourcePath: String = #filePath) -> URL {
        if let path = environment["WT_PERF_RESULTS"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return clientDirectory(sourcePath: sourcePath).appendingPathComponent("build/perf-results.md")
    }

    /// The `client` directory of a path under `client/Packages/<Package>/Tests` or
    /// `client/WTAppTests`; the current directory for anything else.
    static func clientDirectory(sourcePath: String) -> URL {
        for marker in ["/Packages/", "/WTAppTests/"] {
            if let range = sourcePath.range(of: marker, options: .backwards) {
                return URL(fileURLWithPath: String(sourcePath[..<range.lowerBound]), isDirectory: true)
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    private static let lock = NSLock()

    /// Prints the row and appends it to the results file, starting the file with the table's
    /// header when it is missing or empty.  A file that cannot be written is not an error: the
    /// printed row stands.
    static func report(_ row: Row, environment: [String: String]) {
        print("PERF \(row.markdown)")
        append(row, to: resultsURL(environment: environment))
    }

    @discardableResult
    static func append(_ row: Row, to url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if existing == 0 {
                try Data((header + row.markdown + "\n").utf8).write(to: url)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((row.markdown + "\n").utf8))
            }
            return true
        } catch {
            return false
        }
    }
}
