import AppKit
import SwiftUI
import WTInterchange

/// A pop-up over `choices`.
struct ChoicePicker<Value: Hashable & Sendable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [OptionChoice<Value>]

    init(_ title: String, selection: Binding<Value>, choices: [OptionChoice<Value>]) {
        self.title = title
        _selection = selection
        self.choices = choices
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(choices) { Text($0.title).tag($0.value) }
        }
    }
}

/// The Export sheet's accessory view (exporting.adoc, "Client"): *Preset*, *Format*, *What* with
/// the page range, *Include page boundary*, *File names* when several files are written, *After
/// export*, the sync note, the estimated size, why btn:[Export] is refused, and btn:[Options…].
struct ExportAccessory: View {
    @Bindable var model: ExportSheetModel

    var body: some View {
        Form {
            Picker("Preset", selection: $model.presetChoice) {
                Text("None").tag("")
                ForEach(model.presetList) { Text($0.name).tag($0.id) }
            }
            .accessibilityIdentifier("export.preset")
            if let title = model.presetTitle, model.isModified {
                Text(title + " (modified)").italic().font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Save as Preset", text: $model.presetName, prompt: Text("Preset name"))
                Button("Save as Preset…", action: model.savePreset).disabled(model.presetName.isEmpty)
                Button("Delete Preset", action: model.deletePreset).disabled(!model.canDeletePreset)
            }
            Picker("Format", selection: $model.settings.format) {
                ForEach(model.formats, id: \.self) { Text($0.displayName).tag($0) }
            }
            .accessibilityIdentifier("export.format")
            Picker("What", selection: $model.settings.what) {
                ForEach(model.whatChoices, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("export.what")
            if model.usesRange {
                TextField("Pages", text: $model.settings.range, prompt: Text("1-3, 6"))
            }
            Toggle("Include page boundary", isOn: $model.settings.includePageBoundary)
            if model.showsFileNames {
                TextField("File names", text: $model.settings.namePattern)
                Text(model.sampleNames.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Open with", selection: $model.openWithChoice) {
                Text("None").tag("")
                ForEach(model.openWithApplications) { Text($0.name).tag($0.id) }
            }
            Toggle("Reveal in Finder", isOn: $model.settings.revealInFinder)
            ExportNotes(model: model)
            Button("Options…", action: model.showOptions).accessibilityIdentifier("export.options")
        }
        .padding(12)
        .frame(width: 460)
    }
}

/// The lines under the controls: estimated size, sync state, missing images, the refusal.
struct ExportNotes: View {
    let model: ExportSheetModel

    var body: some View {
        if let estimate = model.sizeEstimate {
            Text(estimate).font(.caption).foregroundStyle(.secondary)
        }
        if let note = model.context.syncNote {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        if !model.context.missing.isEmpty {
            Text("Not yet downloaded: " + model.context.missing.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
        }
        if let problem = model.problem {
            Text(problem).font(.caption).foregroundStyle(.red).accessibilityIdentifier("export.problem")
        }
    }
}

/// btn:[Options…]: the chosen format's options with btn:[Done].
struct ExportOptionsSheet: View {
    let model: ExportSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.settings.format.displayName) Options").font(.headline)
            ExportOptionsForm(model: model)
            HStack {
                Spacer()
                Button("Done", action: model.closeOptions).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// The options of the chosen format.
struct ExportOptionsForm: View {
    let model: ExportSheetModel

    var body: some View {
        Form {
            switch model.settings.format.family {
            case .vector: VectorOptionsForm(model: model)
            case .bitmap: BitmapOptionsForm(model: model)
            case .animation: AnimationOptionsForm(model: model)
            case .text: TextOptionsForm(model: model)
            }
        }
    }
}

/// PDF, Adobe Illustrator, EPS, SVG and DXF.
struct VectorOptionsForm: View {
    let model: ExportSheetModel

    var body: some View {
        switch model.settings.format {
        case .pdf: PDFOptionsForm(model: model)
        case .illustrator: IllustratorOptionsForm(model: model)
        case .eps: EPSOptionsForm(model: model)
        case .svg: SVGOptionsForm(model: model)
        default: DXFOptionsForm(model: model)
        }
    }
}

/// export-pdf.adoc: General, Compression, Fonts, Color, Pages and marks, Interactive, PDF/X.
struct PDFOptionsForm: View {
    @Bindable var model: ExportSheetModel

    var body: some View {
        Section("General") {
            ChoicePicker("Version", selection: $model.settings.options.pdf.version, choices: ExportChoices.pdfVersions)
            ChoicePicker("Standard", selection: $model.settings.options.pdf.standard, choices: ExportChoices.pdfStandards)
                .accessibilityIdentifier("export.pdf.standard")
            if let note = model.pdfStandardNote { Text(note).font(.caption).foregroundStyle(.secondary) }
            Toggle("Layers", isOn: $model.settings.options.pdf.layers)
            Toggle("Embed WireTuner document", isOn: $model.settings.options.pdf.embedPackage)
            Toggle("Optimize for fast web view", isOn: $model.settings.options.pdf.linearize)
            Toggle("Include document info", isOn: $model.settings.options.pdf.includeDocumentInfo)
        }
        Section("Compression") {
            ChoicePicker("Color images", selection: $model.settings.options.pdf.colorImages, choices: ExportChoices.pdfImages)
            Stepper("JPEG quality: \(model.settings.options.pdf.jpegQuality)", value: $model.settings.options.pdf.jpegQuality, in: 1...100)
            Toggle("Downsample images", isOn: $model.settings.options.pdf.downsample)
            TextField("Above (ppi)", value: $model.settings.options.pdf.downsampleAbovePPI, format: .number)
            TextField("To (ppi)", value: $model.settings.options.pdf.downsampleToPPI, format: .number)
            Toggle("Compress text and line art", isOn: $model.settings.options.pdf.compressContent)
        }
        Section("Fonts and color") {
            ChoicePicker("Fonts", selection: $model.settings.options.pdf.fonts, choices: ExportChoices.pdfFonts)
            ChoicePicker("Colors", selection: $model.settings.options.pdf.colors, choices: ExportChoices.colors)
            Toggle("Embed color profiles", isOn: $model.settings.options.pdf.embedProfiles)
            Toggle("Preserve overprint", isOn: $model.settings.options.pdf.preserveOverprint)
            Toggle("Preserve spot colors", isOn: $model.settings.options.pdf.preserveSpot)
            TextField("Raster resolution (ppi, 0 = document)", value: $model.settings.options.pdf.rasterPPI, format: .number)
        }
        Section("Pages and marks") {
            ChoicePicker("Page size", selection: $model.settings.options.pdf.pageSize, choices: ExportChoices.pdfPageSizes)
            Toggle("Use document bleed", isOn: $model.settings.options.pdf.useDocumentBleed)
            TextField("Bleed (pt)", value: $model.settings.options.pdf.bleedPoints, format: .number)
        }
        Section("Interactive") {
            Toggle("Links from URLs", isOn: $model.settings.options.pdf.linksFromURLs)
            Toggle("Notes as comments", isOn: $model.settings.options.pdf.notesAsComments)
            Toggle("Bookmarks from page names", isOn: $model.settings.options.pdf.bookmarksFromPageNames)
            SecureField("Open password", text: $model.settings.options.pdf.openPassword)
            SecureField("Permissions password", text: $model.settings.options.pdf.permissionsPassword)
            Toggle("Allow printing", isOn: $model.settings.options.pdf.allowPrinting)
            Toggle("Allow copying", isOn: $model.settings.options.pdf.allowCopying)
            Toggle("Allow editing", isOn: $model.settings.options.pdf.allowEditing)
            if model.pdfPasswordsAsked { Text("The passwords are asked for when you export.").font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(!model.pdfInteractiveAllowed)
    }
}

/// export-vector.adoc, "Adobe Illustrator": *Colors*, *Embed {product} document*, *Include
/// document info*.
struct IllustratorOptionsForm: View {
    @Bindable var model: ExportSheetModel

    var body: some View {
        ChoicePicker("Colors", selection: $model.settings.options.illustrator.colors, choices: ExportChoices.colors)
        Toggle("Embed WireTuner document", isOn: $model.settings.options.illustrator.embedPackage)
        Toggle("Include document info", isOn: $model.settings.options.illustrator.includeDocumentInfo)
    }
}

/// export-vector.adoc, "EPS options".
struct EPSOptionsForm: View {
    @Bindable var model: ExportSheetModel

    var body: some View {
        ChoicePicker("PostScript", selection: $model.settings.options.eps.level, choices: ExportChoices.epsLevels)
        ChoicePicker("Preview", selection: $model.settings.options.eps.preview, choices: ExportChoices.epsPreviews)
        ChoicePicker("Fonts", selection: $model.settings.options.eps.fonts, choices: ExportChoices.epsFonts)
        ChoicePicker("Colors", selection: $model.settings.options.eps.colors, choices: ExportChoices.epsColors)
        Toggle("Preserve overprint", isOn: $model.settings.options.eps.preserveOverprint)
        Toggle("Embed WireTuner document", isOn: $model.settings.options.eps.embedPackage)
        Toggle("Include document info", isOn: $model.settings.options.eps.includeDocumentInfo)
        TextField("Raster resolution (ppi, 0 = document)", value: $model.settings.options.eps.rasterPPI, format: .number)
        Stepper("Gradient steps: \(model.settings.options.eps.gradientSteps)", value: $model.settings.options.eps.gradientSteps, in: 2...4096)
    }
}

/// export-vector.adoc, "SVG options", with the size (*Responsive*, or width and height in a unit).
struct SVGOptionsForm: View {
    @Bindable var model: ExportSheetModel

    var body: some View {
        ChoicePicker("Text", selection: $model.settings.options.svg.text, choices: ExportChoices.svgText)
        ChoicePicker("Object IDs", selection: $model.settings.options.svg.ids, choices: ExportChoices.svgIDs)
        ChoicePicker("Styling", selection: $model.settings.options.svg.styling, choices: ExportChoices.svgStyling)
        ChoicePicker("Images", selection: $model.settings.options.svg.images, choices: ExportChoices.svgImages)
        Toggle("Responsive (view box only)", isOn: $model.settings.options.svg.responsive)
        ChoicePicker("Size unit", selection: $model.settings.options.svg.sizeUnit, choices: ExportChoices.svgUnits)
            .disabled(model.settings.options.svg.responsive)
        Stepper("Decimal places: \(model.settings.options.svg.precision)", value: $model.settings.options.svg.precision, in: 1...6)
        Toggle("Page background", isOn: $model.settings.options.svg.pageBackground)
        Toggle("Minify", isOn: $model.settings.options.svg.minify)
        Toggle("Include document info", isOn: $model.settings.options.svg.includeDocumentInfo)
        TextField("Raster resolution (ppi, 0 = document)", value: $model.settings.options.svg.rasterPPI, format: .number)
    }
}

/// export-vector.adoc, "DXF options".
struct DXFOptionsForm: View {
    @Bindable var model: ExportSheetModel

    var body: some View {
        ChoicePicker("Version", selection: $model.settings.options.dxf.version, choices: ExportChoices.dxfVersions)
        ChoicePicker("Units", selection: $model.settings.options.dxf.units, choices: ExportChoices.dxfUnits)
        Toggle("Curves as splines", isOn: $model.settings.options.dxf.splines)
        Toggle("Layers from the document", isOn: $model.settings.options.dxf.layersFromDocument)
        Toggle("Outline strokes", isOn: $model.settings.options.dxf.outlineStrokes)
    }
}

/// export-bitmap.adoc: the shared options, then the format's own, with the estimated size.
struct BitmapOptionsForm: View {
    @Bindable var model: ExportSheetModel

    var body: some View {
        Section("Size and color") {
            TextField("Resolution (ppi)", value: $model.bitmapCommon.ppi, format: .number)
            HStack {
                Toggle("1×", isOn: $model.scale1x)
                Toggle("2×", isOn: $model.scale2x)
                Toggle("3×", isOn: $model.scale3x)
            }
            ChoicePicker("Anti-aliasing", selection: $model.bitmapCommon.antiAliasing, choices: ExportChoices.antiAliasing)
            ChoicePicker("Background", selection: $model.bitmapCommon.background, choices: ExportChoices.backgrounds)
            ChoicePicker("Color", selection: $model.bitmapCommon.color, choices: ExportChoices.colorModes)
            ChoicePicker("RGB profile", selection: $model.bitmapCommon.rgbSpace, choices: ExportChoices.rgbSpaces)
            Toggle("Embed color profile", isOn: $model.bitmapCommon.embedProfile)
            Toggle("Simulate overprint", isOn: $model.bitmapCommon.simulateOverprint)
        }
        Section(model.settings.format.displayName) {
            BitmapFormatForm(model: model)
            if let estimate = model.sizeEstimate { Text(estimate).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Each bitmap format's own options.
struct BitmapFormatForm: View {
    @Bindable var model: ExportSheetModel

    var body: some View {
        switch model.settings.format {
        case .jpeg:
            Stepper("Quality: \(model.settings.options.jpeg.quality)", value: $model.settings.options.jpeg.quality, in: 1...100)
            Toggle("Progressive", isOn: $model.settings.options.jpeg.progressive)
        case .webp:
            Toggle("Lossless", isOn: $model.settings.options.webp.lossless)
            Stepper("Quality: \(model.settings.options.webp.quality)", value: $model.settings.options.webp.quality, in: 1...100)
        case .heic:
            Stepper("Quality: \(model.settings.options.heic.quality)", value: $model.settings.options.heic.quality, in: 1...100)
        case .avif:
            Stepper("Quality: \(model.settings.options.avif.quality)", value: $model.settings.options.avif.quality, in: 1...100)
            Stepper("Speed: \(model.settings.options.avif.speed)", value: $model.settings.options.avif.speed, in: 0...10)
        case .gif:
            PaletteForm(model: model)
            Toggle("Transparent background", isOn: $model.settings.options.gif.transparent)
            Toggle("Interlaced", isOn: $model.settings.options.gif.interlaced)
        case .tiff:
            ChoicePicker("Compression", selection: $model.settings.options.tiff.compression, choices: ExportChoices.tiffCompression)
            ChoicePicker("Depth", selection: $model.settings.options.tiff.bits, choices: ExportChoices.pngBits)
            if model.settings.options.tiff.bits == 8 { PaletteForm(model: model) }
        case .psd:
            Toggle("Layers", isOn: $model.settings.options.psd.layers)
            ChoicePicker("Depth", selection: $model.settings.options.psd.bitsPerChannel, choices: ExportChoices.psdBits)
        case .bmp:
            ChoicePicker("Depth", selection: $model.settings.options.bmp.bits, choices: ExportChoices.bmpBits)
        case .targa:
            ChoicePicker("Depth", selection: $model.settings.options.targa.bits, choices: ExportChoices.targaBits)
            Toggle("Compress (RLE)", isOn: $model.settings.options.targa.rle)
        default:
            ChoicePicker("Depth", selection: $model.settings.options.png.bits, choices: ExportChoices.pngBits)
            Toggle("Interlaced", isOn: $model.settings.options.png.interlaced)
            Toggle("Fastest compression", isOn: $model.settings.options.png.fast)
            if model.settings.options.png.bits == 8 { PaletteForm(model: model) }
        }
    }
}

/// The palette of the 8-bit depths (export-bitmap.adoc, "Color tables").
struct PaletteForm: View {
    @Bindable var model: ExportSheetModel

    var body: some View {
        ChoicePicker("Palette", selection: $model.palette.choice, choices: ExportChoices.palettes)
        Stepper("Colors: \(model.palette.colors)", value: $model.palette.colors, in: 2...256)
        Stepper("Dither: \(model.palette.ditherPercent)%", value: $model.palette.ditherPercent, in: 0...100)
    }
}

/// animation.adoc, "Exporting an animation": *Size*, *Frame rate*, *Loop*, *Background*,
/// *Pages*, and *Quality* (MP4) or *Colors* and *Dither* (GIF).
struct AnimationOptionsForm: View {
    @Bindable var model: ExportSheetModel

    var body: some View {
        Toggle("Explicit pixel size", isOn: $model.animationUsesPixels)
        if model.animationUsesPixels {
            TextField("Width (px)", value: $model.animationWidth, format: .number)
            TextField("Height (px)", value: $model.animationHeight, format: .number)
        } else {
            TextField("Scale", value: $model.animationScale, format: .number)
        }
        Toggle("Document frame rate", isOn: $model.animationUsesDocumentFPS)
        if !model.animationUsesDocumentFPS {
            TextField("Frames per second", value: $model.animationFPS, format: .number)
        }
        ChoicePicker("Loop", selection: $model.animationLoop, choices: ExportChoices.loops)
        if model.animationLoop == .count {
            Stepper("Plays: \(model.animationLoopCount)", value: $model.animationLoopCount, in: 1...1000)
        }
        ChoicePicker("Background", selection: $model.animationBackground, choices: ExportChoices.animationBackgrounds)
        TextField("Pages", text: $model.animationPages, prompt: Text("All"))
        ChoicePicker("Anti-aliasing", selection: $model.animationCommon.antiAliasing, choices: ExportChoices.antiAliasing)
        switch model.settings.format {
        case .animatedGIF:
            Stepper("Colors: \(model.settings.options.animatedGIF.colors)", value: $model.settings.options.animatedGIF.colors, in: 2...256)
            Stepper("Dither: \(model.settings.options.animatedGIF.ditherPercent)%", value: $model.settings.options.animatedGIF.ditherPercent, in: 0...100)
        case .mp4H264:
            Stepper("Quality: \(model.settings.options.mp4H264.quality)", value: $model.settings.options.mp4H264.quality, in: 1...100)
        case .mp4HEVC:
            Stepper("Quality: \(model.settings.options.mp4HEVC.quality)", value: $model.settings.options.mp4HEVC.quality, in: 1...100)
        default:
            EmptyView()
        }
    }
}

/// export-text.adoc: Rich Text's inline graphics, Plain Text's encoding and line endings.
struct TextOptionsForm: View {
    @Bindable var model: ExportSheetModel

    var body: some View {
        if model.settings.format == .rtf {
            Toggle("Embed inline graphics", isOn: $model.settings.options.rtf.embedInlineGraphics)
        } else {
            ChoicePicker("Encoding", selection: $model.settings.options.text.encoding, choices: ExportChoices.encodings)
            Toggle("Windows line endings (CRLF)", isOn: $model.settings.options.text.crlf)
        }
    }
}

/// The window's progress bar for a running export (exporting.adoc, "Exporting a document": it
/// appears after a second, the window stays usable, and Cancel stops the export).
struct ExportProgressView: View {
    let activity: ExportActivity

    var body: some View {
        HStack(spacing: 10) {
            Text(activity.title).font(.caption).lineLimit(1)
            if let fraction = activity.fraction {
                ProgressView(value: fraction).frame(width: 160)
            } else {
                ProgressView().controlSize(.small)
            }
            Button("Cancel", action: activity.cancel).controlSize(.small).accessibilityIdentifier("export.cancel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

/// Attaches the progress bar to a window as a titlebar accessory, below the toolbar.
@MainActor
enum ExportProgressBar {
    static let identifier = NSUserInterfaceItemIdentifier("export.progress")

    static func attach(_ activity: ExportActivity, to window: NSWindow?) {
        guard let window, !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier == identifier }) else { return }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = identifier
        accessory.layoutAttribute = .bottom
        accessory.view = NSHostingView(rootView: ExportProgressView(activity: activity))
        window.addTitlebarAccessoryViewController(accessory)
    }

    static func detach(from window: NSWindow?) {
        guard let window, let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0.identifier == identifier }) else { return }
        window.removeTitlebarAccessoryViewController(at: index)
    }
}
