import CoreGraphics
import CoreImage
import Foundation
import Testing
import Vision
import WTGeometry
@testable import WTRender

/// DATA-018: the QR and Code 128 encoders, drawn as vector rectangles.
@Suite struct BarcodeTests {
    static let levels = QRErrorCorrection.allCases

    /// `spec` rendered at `scale` pixels per point over white.
    static func render(_ spec: BarcodeSpec, scale: Double) -> CGImage? {
        let item = BarcodeRendering.item(spec)
        let bounds = item.bounds!
        let list = DisplayList(canvas: "barcode", items: [item])
        let viewport = Viewport(scrollOrigin: Point(x: bounds.minX, y: bounds.minY), size: Size(width: bounds.width, height: bounds.height))
        return CoreGraphicsRenderer(background: .white).renderBitmap(list, viewport: viewport, scale: scale)
    }

    static func decodeQR(_ image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
        return detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    static func decodeBarcodes(_ image: CGImage, symbology: VNBarcodeSymbology) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [symbology]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    static let qrFixtures = [
        "https://wiretuner.app/doc/1",
        "Grüße aus Köln — ünïcödé ✓",
        String(repeating: "wiretuner vector illustration ", count: 12),
    ]

    @Test(arguments: qrFixtures)
    func everyQRFixtureDecodesAtEveryLevelAndSize(value: String) throws {
        for level in Self.levels {
            for scale in [2.0, 4.0, 7.0] {
                let image = try #require(Self.render(BarcodeSpec(symbology: .qr, value: value, errorCorrection: level), scale: scale))
                #expect(Self.decodeQR(image) == [value], "level \(level) at \(scale)×")
            }
        }
    }

    @Test func longValuesUseLargeVersionsAndStillDecode() throws {
        let value = String(repeating: "0123456789abcdef", count: 60)
        let code = try QRCode.encode(value, level: .low)
        #expect(code.version >= 20)
        let image = try #require(Self.render(BarcodeSpec(symbology: .qr, value: value, errorCorrection: .low), scale: 3))
        #expect(Self.decodeQR(image) == [value])
    }

    /// Core Image's generator is the cross-check: with the mask it chose, every module matches.
    @Test(arguments: ["hello, wiretuner", "lower case text makes byte mode", "https://example.com/?q=1"])
    func modulesMatchCoreImageWithItsMask(value: String) throws {
        let names: [QRErrorCorrection: String] = [.low: "L", .medium: "M", .quartile: "Q", .high: "H"]
        for level in Self.levels {
            let filter = CIFilter(name: "CIQRCodeGenerator")!
            filter.setValue(Data(value.utf8), forKey: "inputMessage")
            filter.setValue(names[level], forKey: "inputCorrectionLevel")
            let output = try #require(filter.outputImage)
            let cgImage = try #require(CIContext().createCGImage(output, from: output.extent))
            let surface = try #require(BitmapSurface(drawing: cgImage))
            let reference = try QRCode.encode(value, level: level)
            let border = (surface.width - reference.size) / 2
            try #require(surface.width == reference.size + 2 * border, "Core Image chose another version for \(level)")
            func dark(_ x: Int, _ y: Int) -> Bool { surface.pixel(x: x + border, y: y + border).red < 128 }
            // Read Core Image's mask from its format bits (row 8, columns 2...4, unmasked by 0x5412).
            var format = 0
            for i in 0...5 { format |= (dark(8, i) ? 1 : 0) << i }
            format |= (dark(8, 7) ? 1 : 0) << 6
            format |= (dark(8, 8) ? 1 : 0) << 7
            format |= (dark(7, 8) ? 1 : 0) << 8
            for i in 9..<15 { format |= (dark(14 - i, 8) ? 1 : 0) << i }
            let mask = ((format ^ 0x5412) >> 10) & 7
            let mine = try QRCode.encode(value, level: level, mask: mask)
            var mismatches = 0
            for y in 0..<mine.size {
                for x in 0..<mine.size where mine.isDark(x: x, y: y) != dark(x, y) {
                    mismatches += 1
                }
            }
            #expect(mismatches == 0, "\(value) at \(level) with mask \(mask)")
        }
    }

    @Test func versionCapacitiesMatchTheStandard() {
        // ISO 18004 Table 7, byte mode.
        #expect(QRCode.byteCapacity(version: 1, level: .low) == 17)
        #expect(QRCode.byteCapacity(version: 1, level: .high) == 7)
        #expect(QRCode.byteCapacity(version: 10, level: .medium) == 213)
        #expect(QRCode.byteCapacity(version: 40, level: .low) == 2953)
        #expect(QRCode.byteCapacity(version: 40, level: .high) == 1273)
        #expect(QRTables.alignmentPositions(1) == [])
        #expect(QRTables.alignmentPositions(7) == [6, 22, 38])
        #expect(QRTables.alignmentPositions(32) == [6, 34, 60, 86, 112, 138])
    }

    @Test func tooLongValuesAreRefusedAndDrawThePlaceholder() throws {
        let value = String(repeating: "x", count: 3000)
        #expect(throws: QRCode.EncodingError.tooLong(bytes: 3000, capacity: 2953)) {
            try QRCode.encode(value, level: .low)
        }
        let item = BarcodeRendering.item(BarcodeSpec(symbology: .qr, value: value))
        guard case .group(let group) = item else {
            Issue.record("a placeholder is a group")
            return
        }
        #expect(group.atomic)
        #expect(item.ownBounds.map { approx($0, Rect(x: 0, y: 0, width: 29, height: 29), tolerance: 1e-6) } == true)
        #expect(BarcodeRendering.paths(BarcodeSpec(symbology: .qr, value: value)).isEmpty)
    }

    @Test func masksAndPenaltiesAreDeterministic() throws {
        let a = try QRCode.encode("determinism", level: .quartile)
        let b = try QRCode.encode("determinism", level: .quartile)
        #expect(a == b)
        for mask in 0..<8 {
            let forced = try QRCode.encode("determinism", level: .quartile, mask: mask)
            #expect(forced.mask == mask)
            #expect(forced.penalty >= a.penalty)
        }
        #expect(QRCode.finderLikePatterns(in: [true, false, true, true, true, false, true, false, false, false, false]) == 1)
        #expect(QRCode.finderLikePatterns(in: [true, false]) == 0)
        #expect(!a.isDark(x: -1, y: 0))
    }

    // MARK: Code 128

    static let code128Fixtures = ["WT-2026", "hello world", "1234567890", "ABC123456789xyz", "Tab\there", "a1b2c3d4", "000123abc"]

    @Test(arguments: code128Fixtures)
    func everyCode128FixtureDecodes(value: String) throws {
        let image = try #require(Self.render(BarcodeSpec(symbology: .code128, value: value), scale: 3))
        #expect(try Self.decodeBarcodes(image, symbology: .code128) == [value])
    }

    @Test func code128ChoosesSetsForTheShortestSymbol() throws {
        // All digits: start C, two digits per value.
        let digits = try Code128("12345678")
        #expect(digits.values.first == Code128.startC)
        #expect(digits.values.count == 1 + 4 + 1)
        // Mixed: B for letters, C for the digit run.
        let mixed = try Code128("ab123456")
        #expect(mixed.values.first == Code128.startB)
        #expect(mixed.values.contains(99))
        // A control character among upper case: set A.
        let control = try Code128("A\tB")
        #expect(control.values.first == Code128.startA)
        // One lower-case letter inside control characters: a shift, not a change.
        let shifted = try Code128("\t\ta\t\t")
        #expect(shifted.values.contains(98))
        // The check character: start B (104) + 1 × 'A'(33) ... mod 103.
        let single = try Code128("A")
        #expect(single.values == [Code128.startB, 33, (104 + 33) % 103])
        #expect(single.moduleWidth == 3 * 11 + 13)
        #expect(Code128.patterns.dropLast().allSatisfy { $0.reduce(0, +) == 11 })
        #expect(Code128.patterns.last!.reduce(0, +) == 13)
        #expect(Set(Code128.patterns.map { $0.map(String.init).joined() }).count == 107)
    }

    @Test func code128RefusesEmptyAndNonASCII() {
        #expect(throws: Code128.EncodingError.empty) { try Code128("") }
        #expect(throws: Code128.EncodingError.notASCII(offset: 2)) { try Code128("ab€") }
        guard case .failure = BarcodeRendering.geometry(BarcodeSpec(symbology: .code128, value: "é")) else {
            Issue.record("é cannot be encoded")
            return
        }
    }

    @Test func code128ShowsTextAndBarsTakeTheFill() throws {
        let spec = BarcodeSpec(symbology: .code128, value: "WT", quietZone: -1, showText: true, paint: .solid(.registration))
        #expect(spec.effectiveQuietZone == 10)
        let geometry = try BarcodeRendering.geometry(spec, typesetter: CoreTextLabels()).get()
        #expect(geometry.textAnchor != nil)
        #expect(geometry.rectangles.first?.minX == 10)
        let item = BarcodeRendering.item(spec)
        guard case .group(let group) = item else {
            Issue.record("a barcode is a group")
            return
        }
        #expect(group.atomic)
        #expect(group.children.contains { if case .text = $0 { return true } else { return false } })
        #expect(BarcodeSpec(symbology: .qr, value: "x", quietZone: .nan).effectiveQuietZone == 4)
    }

    /// PDF output carries rectangles, never an image.
    @Test func pdfExportContainsRectanglesNotAnImage() throws {
        let item = BarcodeRendering.item(BarcodeSpec(symbology: .qr, value: "vector"))
        let list = DisplayList(canvas: "barcode", items: [item])
        let data = try #require(CoreGraphicsRenderer().renderPDF(list, viewport: Viewport(size: Size(width: 40, height: 40))))
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        let page = try #require(document.page(at: 1))
        let resources = page.dictionary.flatMap { dictionary -> CGPDFDictionaryRef? in
            var value: CGPDFDictionaryRef?
            return CGPDFDictionaryGetDictionary(dictionary, "Resources", &value) ? value : nil
        }
        var xObjects: CGPDFDictionaryRef?
        let hasXObjects = resources.map { CGPDFDictionaryGetDictionary($0, "XObject", &xObjects) } ?? false
        #expect(!hasXObjects || xObjects.map { CGPDFDictionaryGetCount($0) } == 0)
        #expect(BarcodeRendering.paths(BarcodeSpec(symbology: .qr, value: "vector", transform: .translation(x: 5, y: 5))).count > 20)
    }

    /// Hit testing is the bounds rectangle: a light module inside the symbol still hits.
    @Test func hitTestingIsTheBoundsRectangle() throws {
        let item = BarcodeRendering.item(BarcodeSpec(symbology: .qr, value: "hit", quietZone: 4))
        let list = DisplayList(canvas: "barcode", items: [item])
        let tester = HitTester(displayList: list, viewport: Viewport(size: Size(width: 60, height: 60)), options: HitOptions(subselect: true))
        // (2, 2) is in the quiet zone: light, but inside the bounds.
        let hits = tester.hitTest(viewPoint: Point(x: 2, y: 2))
        #expect(hits.map(\.itemPath) == [[0]])
    }
}
