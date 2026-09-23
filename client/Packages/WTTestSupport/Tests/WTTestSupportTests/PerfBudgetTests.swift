import Foundation
import Testing

/// The rule every client timing budget goes through (`Support/PerfBudget.swift`, linked from
/// `WTTestSupport/Shared`; docs/spec/testing.adoc, "Where budgets run").
@Suite struct PerfBudgetTests {
    static let perf = ["WT_PERF": "1"]

    @Test func onlyAPerfRunHoldsABudget() {
        #expect(PerfBudget.decide(environment: [:], isReleaseBuild: true, debugReason: nil, load: 0, cores: 8) == .notRequested)
        #expect(PerfBudget.decide(environment: ["WT_PERF": "0"], isReleaseBuild: true, debugReason: nil, load: 0, cores: 8) == .notRequested)
        #expect(PerfBudget.decide(environment: Self.perf, isReleaseBuild: true, debugReason: nil, load: 1, cores: 8) == .enforced)
        #expect(PerfBudget.isRequested(Self.perf) && !PerfBudget.isRequested([:]))
    }

    @Test func aDebugBuildSkipsUnlessTheBudgetSaysWhy() {
        guard case .skipped(let reason) = PerfBudget.decide(environment: Self.perf, isReleaseBuild: false, debugReason: nil, load: 0, cores: 8) else {
            Issue.record("a debug build's budget is skipped")
            return
        }
        #expect(reason.contains("debug build"))
        #expect(PerfBudget.decide(environment: Self.perf, isReleaseBuild: false, debugReason: "Debug only", load: 0, cores: 8) == .enforced)
    }

    @Test func aLoadedMachineSkipsWithTheMeasuredLoad() {
        #expect(PerfBudget.decide(environment: Self.perf, isReleaseBuild: true, debugReason: nil, load: 97.2, cores: 12)
            == .skipped("load 97.2 over 18.0 (12 cores x 1.5)"))
        // At the limit it still measures; an unreadable load does not skip.
        #expect(PerfBudget.decide(environment: Self.perf, isReleaseBuild: true, debugReason: nil, load: 18, cores: 12) == .enforced)
        #expect(PerfBudget.decide(environment: Self.perf, isReleaseBuild: true, debugReason: nil, load: nil, cores: 12) == .enforced)
        // WT_PERF_LOAD_FACTOR moves the limit; 0 (or less) turns the guard off.
        var environment = Self.perf
        environment["WT_PERF_LOAD_FACTOR"] = "3"
        #expect(PerfBudget.decide(environment: environment, isReleaseBuild: true, debugReason: nil, load: 30, cores: 12) == .enforced)
        #expect(PerfBudget.decide(environment: environment, isReleaseBuild: true, debugReason: nil, load: 40, cores: 12)
            == .skipped("load 40.0 over 36.0 (12 cores x 3.0)"))
        environment["WT_PERF_LOAD_FACTOR"] = "0"
        #expect(PerfBudget.decide(environment: environment, isReleaseBuild: true, debugReason: nil, load: 400, cores: 12) == .enforced)
        environment["WT_PERF_LOAD_FACTOR"] = "busy"
        #expect(PerfBudget.decide(environment: environment, isReleaseBuild: true, debugReason: nil, load: 19, cores: 12) != .enforced)
    }

    @Test func theLoadAverageIsReadable() {
        let load = PerfBudget.loadAverage()
        #expect(load.map { $0 >= 0 } ?? false)
    }

    @Test func measuresAreNamedAfterTheirTest() {
        #expect(PerfBudget.measureName(module: "WTGeometryTests", components: ["PerformanceTests", "boundsInATightLoop()"])
            == "WTGeometry/PerformanceTests.boundsInATightLoop")
        #expect(PerfBudget.measureName(module: "App", components: ["Suite", "case(_:)"]) == "App/Suite.case")
        #expect(PerfBudget.measureName(nil) == "WTTestSupport/PerfBudgetTests.measuresAreNamedAfterTheirTest")
        #expect(PerfBudget.measureName("") == PerfBudget.measureName(nil))
        #expect(PerfBudget.measureName("png") == "WTTestSupport/PerfBudgetTests.measuresAreNamedAfterTheirTest [png]")
    }

    @Test func figuresReadInTheirUnit() {
        #expect(PerfBudget.format(.seconds(2.414)) == "2.41 s")
        #expect(PerfBudget.format(.milliseconds(12.34)) == "12.3 ms")
        #expect(PerfBudget.format(.microseconds(850)) == "850 µs")
        #expect(PerfBudget.format(.zero) == "0 µs")
    }

    @Test func theTableGoesUnderTheClientBuildDirectory() {
        #expect(PerfBudget.clientDirectory(sourcePath: "/r/client/Packages/WTGeometry/Tests/WTGeometryTests/Support/PerfBudget.swift").path == "/r/client")
        #expect(PerfBudget.clientDirectory(sourcePath: "/r/client/WTAppTests/Support/PerfBudget.swift").path == "/r/client")
        #expect(PerfBudget.clientDirectory(sourcePath: "/elsewhere/PerfBudget.swift").path == FileManager.default.currentDirectoryPath)
        #expect(PerfBudget.resultsURL(environment: ["WT_PERF_RESULTS": "/x/perf.md"]).path == "/x/perf.md")
        #expect(PerfBudget.resultsURL(environment: [:]).path.hasSuffix("/client/build/perf-results.md"))
        #expect(PerfBudget.resultsURL(environment: ["WT_PERF_RESULTS": ""]) == PerfBudget.resultsURL(environment: [:]))
    }

    @Test func rowsAppendUnderOneHeader() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PerfBudgetTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("nested/perf-results.md")
        let met = PerfBudget.Row(measure: "A/B.c", measured: "1.0 ms", budget: "2.0 ms", build: "release", result: "met")
        let skipped = PerfBudget.Row(measure: "A/B.d", measured: "3.0 ms", budget: "2.0 ms", build: "debug", result: "skipped: debug build")
        #expect(PerfBudget.append(met, to: file))
        PerfBudget.report(skipped, environment: ["WT_PERF_RESULTS": file.path])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == PerfBudget.header + met.markdown + "\n" + skipped.markdown + "\n")
        #expect(met.markdown == "| A/B.c | 1.0 ms | 2.0 ms | release | met |")
        // An unwritable place is reported by the printed row alone.
        #expect(!PerfBudget.append(met, to: URL(fileURLWithPath: "/dev/null/perf-results.md")))
    }

    @Test func aPerfRunReportsMetMissedAndSkippedBudgets() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PerfBudgetTests-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        let environment = ["WT_PERF": "1", "WT_PERF_RESULTS": file.path]
        func check(_ measured: Duration, knownIssue: String? = nil, release: Bool = true, load: Double = 0) -> PerfBudget.Row? {
            PerfBudget.check(measured, within: .milliseconds(10), "case", enforcedInDebug: nil, knownIssue: knownIssue,
                             environment: environment, isReleaseBuild: release, load: load, cores: 4, sourceLocation: #_sourceLocation)
        }
        #expect(check(.milliseconds(4))?.result == "met")
        withKnownIssue("a missed budget fails the test") {
            #expect(check(.milliseconds(40))?.result == "**missed**")
        }
        // A known issue is recorded as one, and does not fail the test.
        #expect(check(.milliseconds(40), knownIssue: "slow on this Mac")?.result == "**missed** (known issue: slow on this Mac)")
        #expect(check(.milliseconds(40), release: false)?.result.hasPrefix("skipped: debug build") == true)
        #expect(check(.milliseconds(40), load: 7)?.result == "skipped: load 7.0 over 6.0 (4 cores x 1.5)")
        #expect(PerfBudget.check(.seconds(1), within: .zero, nil, enforcedInDebug: nil, knownIssue: nil, environment: [:],
                                 isReleaseBuild: true, load: 0, cores: 4, sourceLocation: #_sourceLocation) == nil)
        let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(rows.count == 2 + 5)
        #expect(rows[2] == "| WTTestSupport/PerfBudgetTests.aPerfRunReportsMetMissedAndSkippedBudgets [case] | 4.0 ms | 10.0 ms | release | met |")
    }

    @Test func outsideAPerfRunNothingIsCheckedOrWritten() {
        // `swift test` without WT_PERF: a figure far over its budget neither fails nor reports.
        guard !PerfBudget.isRequested else {
            return
        }
        #expect(!PerfBudget.isMeasuring)
        PerfBudget.expect(.seconds(10), within: .milliseconds(1))
        PerfBudget.record("10 MiB")
    }

    @Test func buildsAreNamed() {
        #expect(PerfBudget.buildName == (PerfBudget.isReleaseBuild ? "release" : "debug"))
    }
}
