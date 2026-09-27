// veraPDF as an independent PDF/UA-1 validator for the tagged PDF tests (IO-032).  Tests that need it
// run only when `/opt/homebrew/bin/verapdf` exists (`brew install verapdf`).

import Foundation

enum VeraPDF {
    static let path = "/opt/homebrew/bin/verapdf"

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// `verapdf --flavour <flavour>` of `data`: whether it passed and what it printed (the failed
    /// rules, with `--format text`).
    static func validate(_ data: Data, flavour: String = "ua1") throws -> (passed: Bool, output: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wt-verapdf-\(UUID().uuidString).pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--flavour", flavour, "--format", "text", "-v", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        return (text.contains("PASS "), text)
    }
}
