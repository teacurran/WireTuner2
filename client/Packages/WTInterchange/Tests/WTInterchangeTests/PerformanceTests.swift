// IO-021's memory bound for large exports.  Runs only in the perf run (`make client-perf`: release,
// `WT_PERF=1`; one package: `WT_PERF=1 swift test -c release -Xswiftc -enable-testing --filter
// PerformanceTests`), reporting the process's peak resident size after a large PNG and Targa
// export to the perf results (a figure, not a budget; other tests of the run share the process).

import Darwin
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite(.enabled(if: PerfBudget.isMeasuring, "the perf run only: release with WT_PERF=1"))
struct PerformanceTests {
    static func peakResidentMiB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    @Test(arguments: [ExportFormat.targa, .png])
    func largeExportMemory(_ format: ExportFormat) throws {
        // A3 (842 × 1191 pt) at 300 ppi, scale 2, anti-aliasing 4: 7017 × 9925 pixels.
        let items = Corpus.basics + Corpus.gradients.map { $0.transformed(by: .translation(x: 300, y: 600)) }
        let page = Corpus.page(items, width: 842, height: 1191)
        let common = BitmapCommonOptions(ppi: 300, scales: [2], antiAliasing: 4, background: .white)
        let options: any ExportOptions = format == .png ? PNGOptions(common: common, bits: 24) : TargaOptions(common: common, bits: 24)
        let start = Date()
        let summary = try BitmapExporter(format: format).export(scene: Corpus.scene([page]), options: options, to: ExportDestination(url: Corpus.directory().appendingPathComponent("large.\(format.fileExtension)")))
        let figure = "\(Int(Date().timeIntervalSince(start))) s, peak \(Int(Self.peakResidentMiB())) MiB"
        print("\(format): \(summary.files[0].lastPathComponent) in \(figure)")
        PerfBudget.record(figure, "\(format)")
    }
}
