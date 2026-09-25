// qpdf as an independent structural checker for the PDF writer's tests (`qpdf --check`).  Tests
// that need it run only when `/opt/homebrew/bin/qpdf` exists (`brew install qpdf`); otherwise they
// fall back to opening the file with `CGPDFDocument`.

import Foundation

enum QPDF {
    static let path = "/opt/homebrew/bin/qpdf"

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// `qpdf --check` of `data`: the exit status (0 clean, 3 warnings) and what it printed.
    static func check(_ data: Data) throws -> (status: Int32, output: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wt-qpdf-\(UUID().uuidString).pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--check", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
