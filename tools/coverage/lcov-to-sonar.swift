// lcov -> SonarQube generic coverage XML.
//
//     swift tools/coverage/lcov-to-sonar.swift <in.lcov> <out.xml> [--relative-to <dir>]
//
// Reads the lcov tracefile that `xcrun llvm-cov export -format=lcov` writes (DA line records and
// BRDA branch records) and writes the format SonarQube's `sonar.coverageReportPaths` accepts:
//
//     <coverage version="1">
//       <file path="client/Packages/WTCRDT/Sources/WTCRDT/Engine.swift">
//         <lineToCover lineNumber="12" covered="true" branchesToCover="2" coveredBranches="1"/>
//
// Several records for one file (the same source compiled into more than one test binary, or one
// tracefile concatenated from several exports) are merged: a line is covered if any record
// covered it, a branch is taken if any record took it.  Branch attributes are written only for
// lines that carry BRDA records.  With `--relative-to`, paths under that directory are written
// relative to it and paths outside it (toolchain sources, derived test runners) are dropped.
// `--exclude <substring>` (repeatable) drops every file whose path contains the substring; the
// client script uses it to keep dependency checkouts (`/.build/`, `client/build/`) out of the
// report, which would otherwise be tens of megabytes of third-party lines.

import Foundation

struct LineCoverage {
    var hits = 0
    /// Keyed by "block,branch" so the same branch from two records merges rather than doubling.
    var branches: [String: Bool] = [:]
}

struct FileCoverage {
    var lines: [Int: LineCoverage] = [:]
}

enum ConversionError: Error, CustomStringConvertible {
    case usage
    case unreadable(String)
    case malformed(line: Int, text: String)

    var description: String {
        switch self {
        case .usage:
            return "usage: lcov-to-sonar.swift <in.lcov> <out.xml> [--relative-to <dir>] [--exclude <substring>]..."
        case .unreadable(let path):
            return "cannot read \(path)"
        case .malformed(let line, let text):
            return "malformed lcov at line \(line): \(text)"
        }
    }
}

func parse(lcov: String) throws -> [String: FileCoverage] {
    var files: [String: FileCoverage] = [:]
    var current: String?
    var lineNumber = 0
    for rawLine in lcov.split(separator: "\n", omittingEmptySubsequences: false) {
        lineNumber += 1
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("TN:") {
            continue
        }
        if line == "end_of_record" {
            current = nil
            continue
        }
        guard let colon = line.firstIndex(of: ":") else {
            throw ConversionError.malformed(line: lineNumber, text: line)
        }
        let key = line[..<colon]
        let value = line[line.index(after: colon)...]
        switch key {
        case "SF":
            current = String(value)
            if files[current!] == nil {
                files[current!] = FileCoverage()
            }
        case "DA":
            guard let path = current else {
                throw ConversionError.malformed(line: lineNumber, text: line)
            }
            let fields = value.split(separator: ",")
            guard fields.count >= 2, let number = Int(fields[0]), let hits = Int(fields[1]) else {
                throw ConversionError.malformed(line: lineNumber, text: line)
            }
            files[path]!.lines[number, default: LineCoverage()].hits += hits
        case "BRDA":
            guard let path = current else {
                throw ConversionError.malformed(line: lineNumber, text: line)
            }
            let fields = value.split(separator: ",")
            guard fields.count == 4, let number = Int(fields[0]) else {
                throw ConversionError.malformed(line: lineNumber, text: line)
            }
            let taken = fields[3] != "-" && (Int(fields[3]) ?? 0) > 0
            let branchKey = "\(fields[1]),\(fields[2])"
            var lineCoverage = files[path]!.lines[number, default: LineCoverage()]
            lineCoverage.branches[branchKey] = (lineCoverage.branches[branchKey] ?? false) || taken
            files[path]!.lines[number] = lineCoverage
        default:
            // FN, FNDA, FNF, FNH, LF, LH, BRF, BRH: summaries Sonar recomputes itself.
            continue
        }
    }
    return files
}

func escape(_ text: String) -> String {
    var out = ""
    for character in text {
        switch character {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.append(character)
        }
    }
    return out
}

/// Returns the path to write for `path`, or nil when it falls outside `base`.
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

func render(_ files: [String: FileCoverage], relativeTo base: String?, excluding: [String]) -> String {
    var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<coverage version=\"1\">\n"
    for path in files.keys.sorted() {
        guard let shown = displayPath(path, relativeTo: base) else {
            continue
        }
        if excluding.contains(where: { path.contains($0) }) {
            continue
        }
        let file = files[path]!
        xml += "  <file path=\"\(escape(shown))\">\n"
        for number in file.lines.keys.sorted() {
            let line = file.lines[number]!
            xml += "    <lineToCover lineNumber=\"\(number)\" covered=\"\(line.hits > 0)\""
            if !line.branches.isEmpty {
                let covered = line.branches.values.filter { $0 }.count
                xml += " branchesToCover=\"\(line.branches.count)\" coveredBranches=\"\(covered)\""
            }
            xml += "/>\n"
        }
        xml += "  </file>\n"
    }
    xml += "</coverage>\n"
    return xml
}

func run(arguments: [String]) throws {
    var positional: [String] = []
    var base: String?
    var excluding: [String] = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--relative-to", "--exclude":
            index += 1
            guard index < arguments.count else {
                throw ConversionError.usage
            }
            if argument == "--relative-to" {
                base = URL(fileURLWithPath: arguments[index]).standardizedFileURL.path
            } else {
                excluding.append(arguments[index])
            }
        default:
            positional.append(argument)
        }
        index += 1
    }
    guard positional.count == 2 else {
        throw ConversionError.usage
    }
    guard let data = FileManager.default.contents(atPath: positional[0]),
          let lcov = String(data: data, encoding: .utf8) else {
        throw ConversionError.unreadable(positional[0])
    }
    let files = try parse(lcov: lcov)
    let xml = render(files, relativeTo: base, excluding: excluding)
    try xml.write(toFile: positional[1], atomically: true, encoding: .utf8)
    let lines = files.values.reduce(0) { $0 + $1.lines.count }
    FileHandle.standardError.write(Data("lcov-to-sonar: \(files.count) files, \(lines) lines -> \(positional[1])\n".utf8))
}

do {
    try run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
