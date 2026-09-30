// The FreeHand importer (import-formats.adoc, "FreeHand"; IO-041, D-083): FreeHand 3 to MX (11)
// documents and templates, read by the vendored libfreehand (client/Vendor/libfreehand) and
// converted by FreeHandConverter.  menu:File[Import…] places the whole file -- every page's
// artwork, the file's layers as groups named after them -- at its natural size, the pages'
// union.  Opening a FreeHand file as a document (IO-040) uses `pages(_:name:context:)`, which
// keeps each page and the layers (FreeHandImporter+Document.swift once the document importer
// protocol is in).

import Foundation
import WTGeometry
import WTRender

public struct FreeHandImporter: Importer {
    public init() {}

    public var formats: [ImportFormat] { [.freehand] }

    public func probe(_ data: Data, name: String, format: ImportFormat) throws -> ImportDescriptor {
        let records = try FreeHandImporter.records(data, name: name)
        let converter = FreeHandConverter(records: records, name: name)
        let pages = converter.freeHandPages
        let scene = converter.sceneTransform
        let bounds = pages.map { page in Rect(scene.apply(Point(x: page[0], y: page[3])), scene.apply(Point(x: page[2], y: page[1]))) }
            .reduce(Rect.null) { $0.union($1) }
        return ImportDescriptor(format: .freehand, naturalSize: bounds, pageCount: pages.count)
    }

    public func convert(_ data: Data, name: String, format: ImportFormat, options: ImportOptionValues, context: ImportContext) throws -> ImportedScene {
        let conversion = try FreeHandImporter.conversion(data, name: name, context: context)
        guard !conversion.layers.isEmpty else { throw ImportError.empty(name: name) }
        return ImportedScene(kind: .vector, name: name, bounds: conversion.bounds, nodes: conversion.layers, notes: conversion.notes, symbols: conversion.symbols)
    }

    /// The file's pages for opening it as a document: each page's rectangle in the scene's
    /// space, and the layers holding every page's artwork (FreeHand's objects belong to the
    /// pasteboard, not to a page, so a page takes what lies on it).
    public func pages(_ data: Data, name: String, context: ImportContext = ImportContext()) throws -> (pages: [Rect], scene: ImportedScene) {
        let conversion = try FreeHandImporter.conversion(data, name: name, context: context)
        let scene = ImportedScene(kind: .vector, name: name, bounds: conversion.bounds, nodes: conversion.layers, notes: conversion.notes, symbols: conversion.symbols)
        return (conversion.pages, scene)
    }

    static func records(_ data: Data, name: String) throws -> FreeHandRecords {
        let records: FreeHandRecords?
        do {
            records = try FreeHandFile.records(data)
        } catch {
            throw ImportError.unreadable(name: name, reason: "its records could not be read.")
        }
        guard let records else {
            throw ImportError.unreadable(name: name, reason: "it is not a FreeHand document.")
        }
        guard records.recordsRead > 0 || !records.layers.values.isEmpty else {
            throw ImportError.unreadable(name: name, reason: "it is damaged or in a FreeHand version WireTuner cannot read.")
        }
        return records
    }

    static func conversion(_ data: Data, name: String, context: ImportContext) throws -> FreeHandConversion {
        try context.checkSize(data.count, name: name)
        var converter = FreeHandConverter(records: try records(data, name: name), name: name, context: context)
        return converter.convert()
    }
}

/// What a FreeHand import approximated or left out, counted during the conversion and written
/// as the import notice's lines.
struct FreeHandNotes: Hashable, Sendable {
    var blends = 0
    var shadows = 0
    var glows = 0
    var customFills = 0
    var patternStrokes = 0
    var textColumns = 0
    var unreadableImages = 0
    var hiddenLayers: [String] = []
    var tooDeep = false
    /// Lines about the file as a whole (version, damage, records not read).
    var file: [String] = []

    /// Record types WireTuner has no reading for, with what the notice calls them.  Their
    /// objects import without the feature (an envelope's object undistorted, a brush stroke's
    /// path plain) or not at all.
    static let unread: [(record: String, feature: String)] = [
        ("Envelope", "envelopes"),
        ("PerspectiveEnvelope", "perspective projections"),
        ("Extrusion", "3D extrusions"),
        ("BrushStroke", "brush strokes"),
        ("CalligraphicStroke", "calligraphic strokes"),
        ("ContourFill", "contour gradients"),
        ("NewContourFill", "contour gradients"),
        ("ConeFill", "cone gradients"),
        ("TaperedFill", "tapered fills"),
        ("TaperedFillX", "tapered fills"),
        ("RadialFillX", "radial fills"),
        ("NewRadialFill", "radial fills"),
        ("BendFilter", "Bend effects"),
        ("RaggedFilter", "Roughen effects"),
        ("SketchFilter", "Sketch effects"),
        ("TransformFilter", "Transform effects"),
        ("DuetFilter", "Duet effects"),
        ("ExpandFilter", "Expand Stroke effects"),
        ("FWBevelFilter", "bevels"),
        ("FWBlurFilter", "blurs"),
        ("FWFeatherFilter", "feathering"),
        ("FWSharpenFilter", "sharpening"),
        ("GradientMaskFilter", "gradient masks"),
        ("ConnectorLine", "connector lines"),
        ("MultiBlend", "blends on a path"),
        ("TextInPath", "text flowed inside a path"),
        ("PSFill", "PostScript fills"),
        ("PSLine", "PostScript strokes"),
        ("EPSImport", "placed EPS files"),
        ("SwfImport", "placed Flash files"),
        ("ImageFill", "image fills"),
        ("CharacterFill", "character fills"),
        ("MasterPageElement", "master pages"),
    ]

    /// The file-level lines from what `records` says about the file.
    mutating func noteRecords(_ records: FreeHandRecords) {
        if !records.complete {
            let at = records.stoppedAt.map { " at a “\($0)” record" } ?? ""
            file.append("The file could only be read in part (\(records.recordsRead) of \(records.recordCount) records\(at)); the rest is missing.")
        }
        var features: [String] = []
        for (record, feature) in FreeHandNotes.unread where (records.recordTypes[record] ?? 0) > 0 && !features.contains(feature) {
            features.append(feature)
        }
        if !features.isEmpty {
            file.append("Not imported: \(features.joined(separator: ", ")); the objects using them come in without them.")
        }
    }

    /// The notice's lines.
    var messages: [String] {
        var lines = file
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        if blends > 0 { lines.append("\(count(blends, "blend was", "blends were")) imported as groups of their steps.") }
        if shadows > 0 || glows > 0 {
            let parts = [shadows > 0 ? count(shadows, "shadow", "shadows") : nil, glows > 0 ? count(glows, "glow", "glows") : nil].compactMap { $0 }
            lines.append("\(parts.joined(separator: " and ")) \(shadows + glows == 1 ? "was" : "were") left out.")
        }
        if customFills > 0 { lines.append("\(count(customFills, "custom fill was", "custom fills were")) imported as its colour.") }
        if patternStrokes > 0 { lines.append("\(count(patternStrokes, "pattern stroke was", "pattern strokes were")) imported as plain strokes.") }
        if textColumns > 0 { lines.append("\(count(textColumns, "text block with columns or rows was", "text blocks with columns or rows were")) imported as one frame.") }
        if unreadableImages > 0 { lines.append("\(count(unreadableImages, "image could", "images could")) not be read and were left out.") }
        if !hiddenLayers.isEmpty { lines.append("Hidden layers were left out: \(hiddenLayers.joined(separator: ", ")).") }
        if tooDeep { lines.append("Groups nested more than \(FreeHandConverter.maximumDepth) deep were left out.") }
        return lines
    }
}
