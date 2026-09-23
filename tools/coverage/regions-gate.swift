// The client's branch gate: llvm-cov region coverage (docs/spec/decisions.adoc D-066).
//
//     swift tools/coverage/regions-gate.swift <export.json> [--relative-to <dir>]
//         [--exclude <substring>]... [--minimum <percent>] [--minimum-lines <percent>]
//         [--summary <file>]
//
// Reads the JSON that `xcrun llvm-cov export -format=text -summary-only` writes (one export over
// the merged .profdata and every instrumented binary, so each source file appears once with its
// union coverage) and sums the per-file `summary.regions` and `summary.lines` counters over the
// files that survive the filters.  A region is what the compiler's coverage mapping counts
// separately: every `if`/`guard`/`switch` arm, `?:` and `??` operand, loop body and closure
// gets its own counter, so region coverage is the closest thing to branch coverage the Swift
// toolchain produces (Xcode's llvm-cov emits no BRDA/branch records for Swift; see
// docs/spec/testing.adoc, "Coverage and SonarQube").
//
// `--relative-to <dir>` drops files outside the repository (toolchain and derived sources) and
// prints the rest relative to it; `--exclude <substring>` (repeatable) drops dependency
// checkouts, build output, tests and generated code so the denominator is the same set of files
// SonarQube measures.  `--minimum` (default 95) is the region gate: below it the process exits
// 1.  `--minimum-lines` gates lines the same way when given (Sonar gates lines in CI; the flag
// lets a local run apply the same bar).  The figures are printed to stdout and, as a Markdown
// table, appended to `--summary <file>` or to $GITHUB_STEP_SUMMARY when that is set, because
// Sonar's generic coverage format has no field for regions.
//
// Exit codes: 0 gate met, 1 gate not met (or no measurable regions), 2 usage or unreadable input.

import Foundation

struct Counter {
    var count = 0
    var covered = 0

    var percent: Double {
        count == 0 ? 0 : Double(covered) * 100 / Double(count)
    }

    static func += (lhs: inout Counter, rhs: Counter) {
        lhs.count += rhs.count
        lhs.covered += rhs.covered
    }
}

struct FileSummary {
    let path: String
    let lines: Counter
    let regions: Counter
    let branches: Counter
}

enum GateError: Error, CustomStringConvertible {
    case usage(String)
    case unreadable(String)
    case malformed(String)

    var description: String {
        switch self {
        case .usage(let detail):
            return "regions-gate: \(detail)\nusage: regions-gate.swift <export.json> [--relative-to <dir>] [--exclude <substring>]... [--minimum <percent>] [--minimum-lines <percent>] [--summary <file>]"
        case .unreadable(let path):
            return "regions-gate: cannot read \(path)"
        case .malformed(let detail):
            return "regions-gate: not an llvm-cov export: \(detail)"
        }
    }
}

func counter(_ summary: [String: Any], _ key: String) throws -> Counter {
    guard let entry = summary[key] as? [String: Any],
          let count = entry["count"] as? Int, let covered = entry["covered"] as? Int else {
        throw GateError.malformed("summary.\(key) lacks count/covered")
    }
    return Counter(count: count, covered: covered)
}

func parse(export data: Data) throws -> [FileSummary] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw GateError.malformed("top level is not an object")
    }
    guard let type = root["type"] as? String, type == "llvm.coverage.json.export" else {
        throw GateError.malformed("type is not llvm.coverage.json.export")
    }
    guard let exports = root["data"] as? [[String: Any]] else {
        throw GateError.malformed("no data array")
    }
    var files: [FileSummary] = []
    for export in exports {
        guard let entries = export["files"] as? [[String: Any]] else {
            throw GateError.malformed("data entry without files (was the export run with -summary-only?)")
        }
        for entry in entries {
            guard let path = entry["filename"] as? String, let summary = entry["summary"] as? [String: Any] else {
                throw GateError.malformed("file entry without filename/summary")
            }
            files.append(FileSummary(path: path,
                                     lines: try counter(summary, "lines"),
                                     regions: try counter(summary, "regions"),
                                     branches: try counter(summary, "branches")))
        }
    }
    return files
}

/// Returns the path to report for `path`, or nil when it falls outside `base`.
func displayPath(_ path: String, relativeTo base: String?) -> String? {
    guard let base else {
        return path
    }
    let prefix = base.hasSuffix("/") ? base : base + "/"
    guard path.hasPrefix(prefix) else {
        return nil
    }
    return String(path.dropFirst(prefix.count))
}

func format(_ value: Double) -> String {
    String(format: "%.2f", value)
}

func row(_ name: String, _ counter: Counter) -> String {
    "| \(name) | \(counter.covered) | \(counter.count) | \(format(counter.percent))% |"
}

struct Options {
    var input = ""
    var base: String?
    var excluding: [String] = []
    var minimumRegions = 95.0
    var minimumLines: Double?
    var summaryPath: String? = ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"]
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var positional: [String] = []
    var index = 0
    func value(for flag: String) throws -> String {
        index += 1
        guard index < arguments.count else {
            throw GateError.usage("\(flag) needs a value")
        }
        return arguments[index]
    }
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--relative-to":
            options.base = URL(fileURLWithPath: try value(for: argument)).standardizedFileURL.path
        case "--exclude":
            options.excluding.append(try value(for: argument))
        case "--minimum", "--minimum-lines":
            let text = try value(for: argument)
            guard let percent = Double(text), percent >= 0, percent <= 100 else {
                throw GateError.usage("\(argument) wants a percentage, got \(text)")
            }
            if argument == "--minimum" {
                options.minimumRegions = percent
            } else {
                options.minimumLines = percent
            }
        case "--summary":
            options.summaryPath = try value(for: argument)
        default:
            if argument.hasPrefix("--") {
                throw GateError.usage("unknown option \(argument)")
            }
            positional.append(argument)
        }
        index += 1
    }
    guard positional.count == 1 else {
        throw GateError.usage("expected exactly one export.json")
    }
    options.input = positional[0]
    return options
}

func run(_ arguments: [String]) throws -> Int32 {
    let options = try parseOptions(arguments)
    guard let data = FileManager.default.contents(atPath: options.input) else {
        throw GateError.unreadable(options.input)
    }
    var lines = Counter()
    var regions = Counter()
    var branches = Counter()
    var kept: [FileSummary] = []
    for file in try parse(export: data) {
        guard let shown = displayPath(file.path, relativeTo: options.base) else {
            continue
        }
        if options.excluding.contains(where: { file.path.contains($0) }) {
            continue
        }
        kept.append(FileSummary(path: shown, lines: file.lines, regions: file.regions, branches: file.branches))
        lines += file.lines
        regions += file.regions
        branches += file.branches
    }

    var report = "### Client coverage (llvm-cov, \(kept.count) files)\n\n"
    report += "| Measure | Covered | Total | Percent |\n|---|---:|---:|---:|\n"
    report += row("Lines", lines) + "\n"
    report += row("Regions (branch gate, D-066)", regions) + "\n"
    report += row("Branches (llvm-cov emits none for Swift)", branches) + "\n"

    // The files with the most uncovered regions, so a red gate says where to look.
    let worst = kept.filter { $0.regions.count > $0.regions.covered }
        .sorted { ($0.regions.count - $0.regions.covered, $0.path) > ($1.regions.count - $1.regions.covered, $1.path) }
        .prefix(10)
    if !worst.isEmpty {
        report += "\nMost uncovered regions:\n\n| File | Regions covered | Total | Percent |\n|---|---:|---:|---:|\n"
        for file in worst {
            report += row(file.path, file.regions) + "\n"
        }
    }

    var verdicts: [String] = []
    var failed = false
    if regions.count == 0 {
        verdicts.append("FAIL: no measurable regions (empty export or every file excluded)")
        failed = true
    } else if regions.percent < options.minimumRegions {
        verdicts.append("FAIL: region coverage \(format(regions.percent))% is below the \(format(options.minimumRegions))% gate")
        failed = true
    } else {
        verdicts.append("PASS: region coverage \(format(regions.percent))% meets the \(format(options.minimumRegions))% gate")
    }
    if let minimumLines = options.minimumLines {
        if lines.percent < minimumLines {
            verdicts.append("FAIL: line coverage \(format(lines.percent))% is below the \(format(minimumLines))% gate")
            failed = true
        } else {
            verdicts.append("PASS: line coverage \(format(lines.percent))% meets the \(format(minimumLines))% gate")
        }
    }
    report += "\n" + verdicts.map { "**\($0)**" }.joined(separator: "  \n") + "\n"

    print(report, terminator: "")
    if let summaryPath = options.summaryPath, !summaryPath.isEmpty {
        if let handle = FileHandle(forWritingAtPath: summaryPath) {
            handle.seekToEndOfFile()
            handle.write(Data(("\n" + report).utf8))
            handle.closeFile()
        } else {
            try report.write(toFile: summaryPath, atomically: true, encoding: .utf8)
        }
    }
    return failed ? 1 : 0
}

do {
    exit(try run(Array(CommandLine.arguments.dropFirst())))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}
