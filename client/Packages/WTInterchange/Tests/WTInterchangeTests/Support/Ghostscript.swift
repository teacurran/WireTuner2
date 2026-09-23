// Ghostscript as an independent PostScript and PDF interpreter for the writers' tests.  Suites that
// need it are enabled only when `/opt/homebrew/bin/gs` exists (`brew install ghostscript`).

import CoreGraphics
import Foundation
import ImageIO

enum Ghostscript {
    static let path = "/opt/homebrew/bin/gs"

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// Runs gs with `arguments`; the exit status and everything it printed.
    static func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-q", "-dNOPAUSE", "-dBATCH", "-dSAFER"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// Interprets `url` without output (`nullpage`), stopping at the first error.
    static func check(_ url: URL, pdf: Bool = false) throws -> (status: Int32, output: String) {
        try run((pdf ? ["-dPDFSTOPONERROR"] : []) + ["-sDEVICE=nullpage", url.path])
    }

    /// `url` (EPS cropped to its bounding box, or a PDF's first page) rendered at `ppi` with
    /// anti-aliasing, as an image; nil when gs fails.
    static func render(_ url: URL, ppi: Double) throws -> (image: CGImage?, output: String) {
        let out = url.deletingPathExtension().appendingPathExtension("gs.png")
        let result = try run(["-dEPSCrop", "-sDEVICE=png16m", "-r\(Int(ppi))", "-dTextAlphaBits=4", "-dGraphicsAlphaBits=4", "-sOutputFile=\(out.path)", url.path])
        guard result.status == 0, let source = CGImageSourceCreateWithURL(out as CFURL, nil) else {
            return (nil, result.output)
        }
        return (CGImageSourceCreateImageAtIndex(source, 0, nil), result.output)
    }
}
