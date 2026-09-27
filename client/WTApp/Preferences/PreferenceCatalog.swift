import Foundation

// Every preference on docs/_includes/basics/preferences.adoc, one key per value.  The page has
// 123 rows; five rows hold more than one value and map to several keys (`pageRow` names the
// row), which the catalog test checks row by row.  Ids follow the page's naming rule: dotted,
// lower-case, category first; local ones are stored under the same id with the `wt.` prefix.

private func steps(_ range: ClosedRange<Double>, step: Double = 1, _ unit: String) -> PreferenceControl {
    .stepper(range: range, step: step, unit: unit)
}

private func choices(_ options: [(String, String)]) -> PreferenceControl {
    .popup(options.map { PreferenceOption(.string($0.0), $0.1) })
}

private func numberChoices(_ options: [(Int, String)]) -> PreferenceControl {
    .popup(options.map { PreferenceOption(.int($0.0), $0.1) })
}

enum PreferenceCatalog {
    enum General {
        static let c = PreferenceCategory.general
        static let pickDistance = PreferenceKey<Int>("general.pick_distance", "Pick distance", category: c, default: 3, control: steps(1...5, "px"), help: "selecting")
        static let snapDistance = PreferenceKey<Int>("general.snap_distance", "Snap distance", category: c, default: 3, control: steps(1...10, "px"), help: "moving")
        static let smallerHandles = PreferenceKey<Bool>("general.smaller_handles", "Smaller handles", category: c, default: false, control: .toggle)
        static let solidPoints = PreferenceKey<Bool>("general.solid_points", "Show solid points", category: c, default: true, control: .toggle, help: "vector-basics")
        static let highlightSelectedPaths = PreferenceKey<Bool>("general.highlight_selected_paths", "Highlight selected paths", category: c, default: true, control: .toggle, help: "layers")
        static let doubleClickTransform = PreferenceKey<Bool>("general.double_click_transform", "Double-click enables transform handles", category: c, default: true, control: .toggle, help: "transforming")
        static let rememberLayerInfo = PreferenceKey<Bool>("general.remember_layer_info", "Remember layer info", category: c, default: false, control: .toggle, help: "copying")
        static let guideDragScrolls = PreferenceKey<Bool>("general.guide_drag_scrolls", "Dragging a guide scrolls the window", category: c, default: true, control: .toggle, help: "grid-guides")
        static let penPreview = PreferenceKey<Bool>("general.pen_preview", "Pen tool preview", category: c, default: true, control: .toggle, help: "pen-bezigon")
        static let smootherEditing = PreferenceKey<Bool>("general.smoother_editing", "Smoother editing", category: c, default: true, control: .toggle, help: "editing-paths")
        static let showGalleryAtLaunch = PreferenceKey<Bool>("general.show_gallery_at_launch", "Show the gallery at launch", category: c, default: true, control: .toggle, help: "templates")
        static let flashRemoteChanges = PreferenceKey<Bool>("general.flash_remote_changes", "Flash changes by others", category: c, default: true, control: .toggle, help: "collaboration")
        static let smartGuides = PreferenceKey<Bool>("general.smart_guides", "Smart guides", category: c, default: true, control: .toggle, help: "moving")
        static let optionMeasurements = PreferenceKey<Bool>("general.option_measurements", "Show measurements while holding Option", category: c, default: true, control: .toggle, help: "moving")
        static let trackpadRotate = PreferenceKey<Bool>("general.trackpad_rotate", "Rotate canvas with trackpad", category: c, default: true, control: .toggle, help: "document-view")

        static let all: [AnyPreferenceKey] = [
            pickDistance.erased, snapDistance.erased, smallerHandles.erased, solidPoints.erased,
            highlightSelectedPaths.erased, doubleClickTransform.erased, rememberLayerInfo.erased,
            guideDragScrolls.erased, penPreview.erased, smootherEditing.erased, showGalleryAtLaunch.erased,
            flashRemoteChanges.erased, smartGuides.erased, optionMeasurements.erased, trackpadRotate.erased,
        ]
    }

    enum Object {
        static let c = PreferenceCategory.object
        static let optionDragCopies = PreferenceKey<Bool>("object.option_drag_copies", "Option-drag copies paths", category: c, default: true, control: .toggle, help: "copying")
        static let changeSetsDefaults = PreferenceKey<Bool>("object.change_sets_defaults", "Changing object changes defaults", category: c, default: false, control: .toggle, help: "default-attributes")
        static let showFillOpenPaths = PreferenceKey<Bool>("object.show_fill_open_paths", "Show fill for new open paths", category: c, default: false, control: .toggle, help: "vector-basics")
        static let editLocked = PreferenceKey<Bool>("object.edit_locked", "Edit locked objects", category: c, default: false, control: .toggle, help: "selecting")
        static let pathOperationsConsume = PreferenceKey<Bool>("object.path_ops_consume", "Path operations consume original paths", category: c, default: true, control: .toggle, help: "combining-paths")
        static let joinNonTouching = PreferenceKey<Bool>("object.join_non_touching", "Join non-touching paths", category: c, default: false, control: .toggle, help: "combining-paths")
        static let defaultLineWeights = PreferenceKey<[String]>("object.default_line_weights", "Default line weights", category: c, default: ["0.5", "1", "2", "4", "8", "12", "16", "24"], control: .list, help: "stroke-attributes")
        static let autoApplyStyles = PreferenceKey<Bool>("object.auto_apply_styles", "Auto-apply new styles to selection", category: c, default: true, control: .toggle, help: "styles")
        static let confirmExternalEditor = PreferenceKey<Bool>("object.confirm_external_editor", "Confirm before opening an external editor", category: c, default: true, control: .toggle, help: "external-editors")
        static let externalEditor = PreferenceKey<String>("object.external_editors", "Default image editor", category: c, scope: .local, default: "", control: .chooser(placeholder: "System default"), help: "external-editors")
        static let autoJoinPaths = PreferenceKey<Bool>("object.auto_join_paths", "Auto-join paths", category: c, default: true, control: .toggle, help: "pen-bezigon")
        static let editCurrentLayerOnly = PreferenceKey<Bool>("object.edit_current_layer_only", "Edit current layer only", category: c, default: false, control: .toggle, help: "layers")
        static let constrainAngle = PreferenceKey<Double>("object.constrain_angle", "Constrain angle", category: c, default: 0, control: steps(-180...180, step: 0.5, "°"), help: "transforming")
        static let arrowDistance = PreferenceKey<Double>("object.arrow_distance", "Arrow key distance", category: c, default: 1, control: steps(1...864, "pt"), help: "moving")
        static let shiftArrowDistance = PreferenceKey<Double>("object.shift_arrow_distance", "Shift-arrow key distance", category: c, default: 10, control: steps(1...864, "pt"), help: "moving")

        static let all: [AnyPreferenceKey] = [
            optionDragCopies.erased, changeSetsDefaults.erased, showFillOpenPaths.erased, editLocked.erased,
            pathOperationsConsume.erased, joinNonTouching.erased, defaultLineWeights.erased, autoApplyStyles.erased,
            confirmExternalEditor.erased, externalEditor.erased, autoJoinPaths.erased, editCurrentLayerOnly.erased,
            constrainAngle.erased, arrowDistance.erased, shiftArrowDistance.erased,
        ]
    }

    enum Text {
        static let c = PreferenceCategory.text
        static let autoExpand = PreferenceKey<Bool>("text.auto_expand", "New text containers auto-expand", category: c, default: true, control: .toggle, help: "creating-text")
        static let handlesWithoutRuler = PreferenceKey<Bool>("text.handles_without_ruler", "Show text handles when ruler is off", category: c, default: true, control: .toggle, help: "text-blocks")
        static let alwaysUseEditor = PreferenceKey<Bool>("text.always_use_editor", "Always use text editor", category: c, default: false, control: .toggle, help: "editing-text")
        static let smartQuotes = PreferenceKey<Bool>("text.smart_quotes", "Smart quotes", category: c, default: true, control: .toggle, help: "editing-text")
        static let smartQuotesStyle = PreferenceKey<String>("text.smart_quotes_style", "Smart quotes style", category: c, default: "english", control: choices([
            ("english", "“ ” ‘ ’"), ("german", "„ “ ‚ ‘"), ("guillemets", "« » ‹ ›"),
            ("guillemets_reversed", "» « › ‹"), ("swedish", "” ” ’ ’"), ("corner", "「 」 『 』"),
        ]), help: "editing-text", pageRow: "Smart quotes")
        static let trackTabLine = PreferenceKey<Bool>("text.track_tab_line", "Track tab movement with vertical line", category: c, default: true, control: .toggle, help: "tabs-indents")
        static let styleDragScope = PreferenceKey<String>("text.style_drag_scope", "Dragging a text style changes", category: c, default: "paragraph", control: choices([("paragraph", "Single paragraph"), ("block", "Whole text block")]), help: "text-styles")
        static let styleBasedOn = PreferenceKey<String>("text.style_based_on", "Build text styles based on", category: c, default: "first_paragraph", control: choices([("first_paragraph", "First paragraph"), ("shared", "Shared attributes")]), help: "text-styles")
        static let previewFonts = PreferenceKey<Bool>("text.preview_fonts", "Preview fonts in menus", category: c, default: true, control: .toggle, help: "type-specifications")
        static let toolRevertsToPointer = PreferenceKey<Bool>("text.tool_reverts", "Text tool reverts to Pointer", category: c, default: true, control: .toggle, help: "creating-text")
        static let fontSubstitutions = PreferenceKey<[String]>("text.font_substitutions", "Font substitutions", category: c, default: [], control: .substitutionTable, help: "font-substitution")
        static let defaultSubstitute = PreferenceKey<String>("text.default_substitute", "Default substitute", category: c, default: "Helvetica Neue", control: .text(placeholder: "Helvetica Neue"), help: "font-substitution", pageRow: "Font substitutions")

        static let all: [AnyPreferenceKey] = [
            autoExpand.erased, handlesWithoutRuler.erased, alwaysUseEditor.erased, smartQuotes.erased,
            smartQuotesStyle.erased, trackTabLine.erased, styleDragScope.erased, styleBasedOn.erased,
            previewFonts.erased, toolRevertsToPointer.erased, fontSubstitutions.erased, defaultSubstitute.erased,
        ]
    }

    enum Document {
        static let c = PreferenceCategory.document
        static let restoreView = PreferenceKey<Bool>("document.restore_view", "Restore view when opening document", category: c, default: true, control: .toggle, help: "document-view")
        static let rememberWindow = PreferenceKey<Bool>("document.remember_window", "Remember window size and location", category: c, scope: .local, default: true, control: .toggle)
        static let newTemplate = PreferenceKey<String>("document.new_template", "New document template", category: c, default: "", control: .templateChooser, help: "templates")
        /// menu:File[Open Recent]'s documents across the account's Macs, newest first (DOC-020;
        /// `RecentDocuments`): not a row of the window.
        static let recents = PreferenceKey<[String]>("document.recents", "Recent documents", category: c, default: [], control: .hidden, help: "creating-opening")
        static let warnUnsyncedQuit = PreferenceKey<Bool>("document.warn_unsynced_quit", "Warn when quitting with unsynced changes", category: c, default: true, control: .toggle, help: "saving")
        static let searchMissingLinks = PreferenceKey<Bool>("document.search_missing_links", "Search for missing links", category: c, default: true, control: .toggle, help: "linking-embedding")
        static let missingLinksFolder = PreferenceKey<String>("document.missing_links_folder", "Missing links folder", category: c, scope: .local, default: "", control: .chooser(placeholder: "No folder"), help: "linking-embedding", pageRow: "Search for missing links")
        static let viewSetsPage = PreferenceKey<Bool>("document.view_sets_page", "Changing view sets the active page", category: c, default: true, control: .toggle, help: "pages")
        static let toolsSetPage = PreferenceKey<Bool>("document.tools_set_page", "Using tools sets the active page", category: c, default: true, control: .toggle, help: "pages")
        static let askVersionName = PreferenceKey<Bool>("document.ask_version_name", "Ask for a version name when saving", category: c, default: true, control: .toggle, help: "saving")
        static let lowResolutionWarning = PreferenceKey<Int>("document.low_resolution_warning", "Warn when image resolution is below", category: c, default: 150, control: steps(1...2400, "ppi"), help: "bitmaps")

        static let all: [AnyPreferenceKey] = [
            restoreView.erased, rememberWindow.erased, newTemplate.erased, warnUnsyncedQuit.erased,
            searchMissingLinks.erased, missingLinksFolder.erased, viewSetsPage.erased, toolsSetPage.erased,
            askVersionName.erased, lowResolutionWarning.erased, recents.erased,
        ]
    }

    enum Import {
        static let c = PreferenceCategory.importing
        static let embedImages = PreferenceKey<Bool>("import.embed_images", "Embed images upon import", category: c, default: true, control: .toggle, help: "linking-embedding")
        static let convertEditableEPS = PreferenceKey<Bool>("import.convert_editable_eps", "Convert editable EPS when imported", category: c, default: true, control: .toggle, help: "import-formats")
        static let pdfNotes = PreferenceKey<Bool>("import.pdf_notes", "PDF import: Import notes", category: c, default: true, control: .toggle, help: "import-formats")
        static let pdfURLs = PreferenceKey<Bool>("import.pdf_urls", "PDF import: Import URLs", category: c, default: true, control: .toggle, help: "import-formats")
        static let dxfInvisibleAttributes = PreferenceKey<Bool>("import.dxf_invisible_attributes", "DXF: Import invisible block attributes", category: c, default: false, control: .toggle, help: "import-formats")
        static let dxfWhiteStrokesBlack = PreferenceKey<Bool>("import.dxf_white_strokes_black", "DXF: Convert white strokes to black", category: c, default: true, control: .toggle, help: "import-formats")
        static let dxfWhiteFillsBlack = PreferenceKey<Bool>("import.dxf_white_fills_black", "DXF: Convert white fills to black", category: c, default: false, control: .toggle, help: "import-formats")
        static let pasteFormats = PreferenceKey<[String]>("import.paste_formats", "Paste formats", category: c, scope: .local, default: ["PDF", "SVG", "WireTuner", "Image", "Text"], control: .list, help: "copying")
        static let downsampleMegapixels = PreferenceKey<Int>("import.downsample_megapixels", "Downsample images larger than", category: c, default: 50, control: numberChoices([(0, "Off"), (20, "20 megapixels"), (50, "50 megapixels"), (100, "100 megapixels")]), help: "importing")
        static let embeddedProfiles = PreferenceKey<String>("import.embedded_profiles", "Embedded image profiles", category: c, default: "use", control: choices([("use", "Use embedded"), ("ask", "Ask"), ("ignore", "Ignore")]), help: "image-color")

        static let all: [AnyPreferenceKey] = [
            embedImages.erased, convertEditableEPS.erased, pdfNotes.erased, pdfURLs.erased,
            dxfInvisibleAttributes.erased, dxfWhiteStrokesBlack.erased, dxfWhiteFillsBlack.erased,
            pasteFormats.erased, downsampleMegapixels.erased, embeddedProfiles.erased,
        ]
    }

    enum Export {
        static let c = PreferenceCategory.exporting
        /// *Clipboard formats* (OBJ-015): the formats a Copy writes besides WireTuner's own.
        static let copyFormats = PreferenceKey<[String]>("export.copy_formats", "Clipboard formats", category: c, scope: .local,
                                                         default: ["WireTuner", "PDF", "SVG", "Image", "Rich text", "Plain text"], control: .list, help: "copying")
        static let convertColors = PreferenceKey<String>("export.convert_colors", "Convert colors to", category: c, default: "cmykAndRGB",
                                                         control: choices([("cmyk", "CMYK"), ("rgb", "RGB"), ("cmykAndRGB", "CMYK and RGB")]), help: "copying")
        static let clipboardResolution = PreferenceKey<Int>("export.clipboard_resolution", "Clipboard image resolution", category: c, default: 144,
                                                            control: steps(72...2400, "ppi"), help: "copying")
        static let epsTIFFPreview = PreferenceKey<Bool>("export.eps_tiff_preview", "Include TIFF preview in EPS", category: c, default: true, control: .toggle, help: "export-vector")
        static let quickLookThumbnail = PreferenceKey<Bool>("export.quicklook_thumbnail", "Include Quick Look thumbnail", category: c, default: true, control: .toggle, help: "exporting")
        static let bitmapResolution = PreferenceKey<Int>("export.bitmap_resolution", "Bitmap export resolution", category: c, default: 72, control: numberChoices([(72, "72 dpi"), (144, "144 dpi"), (300, "300 dpi")]), help: "export-bitmap")
        static let bitmapAntialiasing = PreferenceKey<Int>("export.bitmap_antialiasing", "Bitmap export anti-aliasing", category: c, default: 4, control: numberChoices([(1, "None"), (2, "2"), (3, "3"), (4, "4")]), help: "export-bitmap")
        static let defaultBackground = PreferenceKey<String>("export.default_background", "Default background", category: c, default: "transparent", control: choices([("transparent", "Transparent"), ("page", "Page color")]), help: "export-bitmap")
        static let embedProfile = PreferenceKey<Bool>("export.embed_profile", "Embed color profile", category: c, default: true, control: .toggle, help: "export-bitmap")
        static let quickExportPreset = PreferenceKey<String>("export.quick_export_preset", "Quick Export preset", category: c, default: "PNG 1× 2× 3×", control: .text(placeholder: "PNG 1× 2× 3×"), help: "exporting")
        static let dragFormat = PreferenceKey<String>("export.drag_format", "Drag export format", category: c, default: "pdf", control: choices([("pdf", "PDF"), ("svg", "SVG"), ("png", "PNG"), ("jpeg", "JPEG"), ("tiff", "TIFF")]), help: "exporting")
        static let pageNamePattern = PreferenceKey<String>("export.page_name_pattern", "Multi-page file name pattern", category: c, default: "{name}-{page}", control: .text(placeholder: "{name}-{page}"), help: "exporting")
        static let openWith = PreferenceKey<[String]>("export.open_with", "Open exported file with", category: c, scope: .local, default: [], control: .list, help: "exporting")
        static let previewBrowser = PreferenceKey<String>("export.preview_browser", "Preview browser", category: c, scope: .local, default: "", control: .chooser(placeholder: "System default"), help: "svg-animation")

        static let all: [AnyPreferenceKey] = [
            copyFormats.erased, convertColors.erased, clipboardResolution.erased, epsTIFFPreview.erased, quickLookThumbnail.erased,
            bitmapResolution.erased, bitmapAntialiasing.erased, defaultBackground.erased, embedProfile.erased,
            quickExportPreset.erased, dragFormat.erased, pageNamePattern.erased, openWith.erased, previewBrowser.erased,
        ]
    }

    enum Spelling {
        static let c = PreferenceCategory.spelling
        static let findDuplicates = PreferenceKey<Bool>("spelling.find_duplicates", "Find duplicate words", category: c, default: true, control: .toggle, help: "editing-text")
        static let findCapitalization = PreferenceKey<Bool>("spelling.find_capitalization", "Find capitalization errors", category: c, default: true, control: .toggle, help: "editing-text")
        static let ignoreNumbers = PreferenceKey<Bool>("spelling.ignore_numbers", "Ignore words with numbers", category: c, default: false, control: .toggle, help: "editing-text")
        static let ignoreAddresses = PreferenceKey<Bool>("spelling.ignore_addresses", "Ignore internet and file addresses", category: c, default: true, control: .toggle, help: "editing-text")
        static let ignoreUppercase = PreferenceKey<Bool>("spelling.ignore_uppercase", "Ignore words in uppercase", category: c, default: false, control: .toggle, help: "editing-text")
        static let dictionary = PreferenceKey<String>("spelling.dictionary", "Dictionary", category: c, default: "", control: .text(placeholder: "Automatic by language"), help: "editing-text")
        static let checkWhileTyping = PreferenceKey<Bool>("spelling.check_while_typing", "Check spelling while typing", category: c, default: true, control: .toggle, help: "editing-text")
        static let learnedWordCase = PreferenceKey<String>("spelling.learned_word_case", "Add words to dictionary", category: c, default: "as_typed", control: choices([("as_typed", "Exactly as typed"), ("lowercase", "In lowercase")]), help: "editing-text")

        static let all: [AnyPreferenceKey] = [
            findDuplicates.erased, findCapitalization.erased, ignoreNumbers.erased, ignoreAddresses.erased,
            ignoreUppercase.erased, dictionary.erased, checkWhileTyping.erased, learnedWordCase.erased,
        ]
    }

    enum Colors {
        static let c = PreferenceCategory.colors
        static let profilesRow = "Monitor, composite and separations profiles"
        static let guideColor = PreferenceKey<PreferenceColor>("colors.guide_color", "Guide color", category: c, default: .cyan, control: .color, help: "grid-guides")
        static let gridColor = PreferenceKey<PreferenceColor>("colors.grid_color", "Grid color", category: c, default: .lightGray, control: .color, help: "grid-guides")
        static let smartGuideColor = PreferenceKey<PreferenceColor>("colors.smart_guide_color", "Smart guide color", category: c, scope: .local, default: .magenta, control: .color, help: "moving")
        static let splitColorBox = PreferenceKey<Bool>("colors.split_color_box", "Color Mixer and Tints panels use split color box", category: c, default: true, control: .toggle, help: "color-mixer")
        static let defaultColorSpace = PreferenceKey<String>("colors.default_space", "Default color space for new colors", category: c, default: "display_p3", control: choices([("srgb", "sRGB"), ("display_p3", "Display P3")]), help: "color-mixer")
        static let autoRename = PreferenceKey<Bool>("colors.auto_rename", "Auto-rename colors", category: c, default: true, control: .toggle, help: "editing-colors")
        static let swatchTarget = PreferenceKey<String>("colors.swatch_target", "Swatches apply color to", category: c, default: "text", control: choices([("text", "Text"), ("block", "Text block")]), help: "text-color")
        static let colorManagement = PreferenceKey<String>("colors.color_management", "Color management", category: c, scope: .local, default: "colorsync", control: choices([("none", "None"), ("colorsync", "Apple ColorSync")]), help: "color-management")
        static let manageSpotColors = PreferenceKey<Bool>("colors.manage_spot", "Color manage spot colors", category: c, default: false, control: .toggle, help: "color-management")
        static let monitorProfile = PreferenceKey<String>("colors.monitor_profile", "Monitor profile", category: c, scope: .local, default: "", control: .chooser(placeholder: "System default"), help: "color-profiles", pageRow: profilesRow)
        static let compositeProfile = PreferenceKey<String>("colors.composite_profile", "Composite profile", category: c, scope: .local, default: "", control: .chooser(placeholder: "System default"), help: "color-profiles", pageRow: profilesRow)
        static let separationsProfile = PreferenceKey<String>("colors.separations_profile", "Separations profile", category: c, scope: .local, default: "", control: .chooser(placeholder: "System default"), help: "color-profiles", pageRow: profilesRow)

        static let all: [AnyPreferenceKey] = [
            guideColor.erased, gridColor.erased, smartGuideColor.erased, splitColorBox.erased,
            defaultColorSpace.erased, autoRename.erased, swatchTarget.erased, colorManagement.erased,
            manageSpotColors.erased, monitorProfile.erased, compositeProfile.erased, separationsProfile.erased,
        ]
    }

    enum Panels {
        static let c = PreferenceCategory.panels
        static let labelStyle = PreferenceKey<String>("panels.label_style", "Label panel tabs with", category: c, default: "text_and_icon", control: choices([("text", "Text only"), ("icon", "Icon only"), ("text_and_icon", "Text and icon")]), help: "panels")
        static let showTooltips = PreferenceKey<Bool>("panels.show_tooltips", "Show tooltips", category: c, default: true, control: .toggle, help: "toolbars")
        static let layerClickMoves = PreferenceKey<Bool>("panels.layer_click_moves", "Clicking a layer name moves selected objects", category: c, default: true, control: .toggle, help: "layers")

        static let all: [AnyPreferenceKey] = [labelStyle.erased, showTooltips.erased, layerClickMoves.erased]
    }

    enum Redraw {
        static let c = PreferenceCategory.redraw
        static let previewDrag = PreferenceKey<Int>("redraw.preview_drag", "Preview drag", category: c, default: 200, control: steps(0...100_000, "objects"), help: "document-view")
        static let textEffects = PreferenceKey<Bool>("redraw.text_effects", "Display text effects", category: c, default: true, control: .toggle, help: "text-effects")
        static let greekBelow = PreferenceKey<Int>("redraw.greek_below", "Greek type below", category: c, default: 8, control: steps(0...200, "px"), help: "document-view")
        static let imageDisplay = PreferenceKey<String>("redraw.image_display", "Image display", category: c, default: "high", control: choices([("high", "High resolution"), ("proxy", "Proxy"), ("gray", "Gray boxes")]), help: "bitmaps")
        static let rasterEffectPreview = PreferenceKey<String>("redraw.raster_effect_preview", "Raster effect preview", category: c, default: "screen", control: choices([("screen", "Screen resolution"), ("document", "Document resolution"), ("draft", "Draft"), ("off", "Off")]), help: "raster-effects")

        static let all: [AnyPreferenceKey] = [previewDrag.erased, textEffects.erased, greekBelow.erased, imageDisplay.erased, rasterEffectPreview.erased]
    }

    enum Sounds {
        static let c = PreferenceCategory.sounds
        /// "None" plus the macOS system alert sounds (`NSSound(named:)`).
        static let control = choices([("", "None")] + [
            "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
        ].map { ($0, $0) })
        static let snapPoint = PreferenceKey<String>("sounds.snap_point", "Snap to point sound", category: c, default: "", control: control)
        static let snapObject = PreferenceKey<String>("sounds.snap_object", "Snap to object sound", category: c, default: "", control: control)
        static let snapGrid = PreferenceKey<String>("sounds.snap_grid", "Snap to grid sound", category: c, default: "", control: control)
        static let snapGuide = PreferenceKey<String>("sounds.snap_guide", "Snap to guide sound", category: c, default: "", control: control)

        static let all: [AnyPreferenceKey] = [snapPoint.erased, snapObject.erased, snapGrid.erased, snapGuide.erased]
    }

    enum Sync {
        static let c = PreferenceCategory.sync
        static let enabled = PreferenceKey<Bool>("sync.enabled", "Sync preferences with my account", category: c, scope: .local, default: true, control: .toggle)
        static let undoLevels = PreferenceKey<Int>("sync.undo_levels", "Undo levels", category: c, default: 100, control: steps(1...1000, "steps"), help: "undo")
        static let autoMergeBelow = PreferenceKey<Int>("sync.auto_merge_below", "Auto-merge below", category: c, default: 500, control: steps(0...1_000_000, "changes"), help: "collaboration")
        static let askOverlapCount = PreferenceKey<Int>("sync.ask_overlap_count", "Ask when overlap exceeds", category: c, default: 20, control: steps(0...1_000_000, "objects"), help: "collaboration")
        static let askOverlapShare = PreferenceKey<Int>("sync.ask_overlap_share", "Ask when overlap share exceeds", category: c, default: 25, control: steps(0...100, "%"), help: "collaboration")
        static let alwaysAsk = PreferenceKey<Bool>("sync.always_ask", "Always ask when anything overlaps", category: c, default: false, control: .toggle, help: "collaboration")
        static let suggestReviewAfterHours = PreferenceKey<Int>("sync.suggest_review_after_hours", "Suggest review after", category: c, default: 12, control: steps(1...720, "hours"), help: "collaboration")
        static let keepBothOffset = PreferenceKey<Double>("sync.keep_both_offset", "Keep both offset", category: c, default: 10, control: steps(0...1000, "pt"), help: "collaboration")
        static let sharePresence = PreferenceKey<Bool>("sync.share_presence", "Show my cursor and selection to others", category: c, default: true, control: .toggle, help: "presence")
        static let showCursors = PreferenceKey<Bool>("sync.show_cursors", "Show others' cursors", category: c, default: true, control: .toggle, help: "presence")
        static let showSelections = PreferenceKey<Bool>("sync.show_selections", "Show others' selections", category: c, default: true, control: .toggle, help: "presence")
        static let snapshotIntervalMinutes = PreferenceKey<Int>("sync.snapshot_interval_minutes", "Offline snapshot interval", category: c, scope: .local, default: 5, control: steps(1...60, "minutes"), help: "offline")
        static let showCursorNames = PreferenceKey<Bool>("sync.show_cursor_names", "Show names on collaborators' cursors", category: c, default: true, control: .toggle, help: "presence")
        static let showCommentPins = PreferenceKey<Bool>("sync.comments_show_pins", "Show Pins", category: c, default: true, control: .toggle, help: "comments")
        static let showResolvedPins = PreferenceKey<Bool>("sync.comments_show_resolved", "Show Resolved Pins", category: c, default: false, control: .toggle, help: "comments")
        static let pinsFollowFilter = PreferenceKey<Bool>("sync.comments_follow_filter", "Pins Follow Filter", category: c, default: false, control: .toggle, help: "comments")
        // The Inspect panel's *Unit* and *Scale* pop-ups (inspect.adoc, "Units and scale"; COLLAB-037), local to this Mac.
        static let inspectUnit = PreferenceKey<String>("sync.inspect_unit", "Inspect unit", category: c, scope: .local, default: "document", control: choices([
            ("document", "Document units"), ("points", "Points"), ("pixels", "Pixels"), ("millimeters", "Millimeters"), ("centimeters", "Centimeters"),
            ("inches", "Inches"),
        ]), help: "inspect")
        static let inspectScale = PreferenceKey<Double>("sync.inspect_scale", "Inspect scale", category: c, scope: .local, default: 1, control: steps(0.1...16, step: 0.1, "×"), help: "inspect")

        static let all: [AnyPreferenceKey] = [
            enabled.erased, undoLevels.erased, autoMergeBelow.erased, askOverlapCount.erased, askOverlapShare.erased,
            alwaysAsk.erased, suggestReviewAfterHours.erased, keepBothOffset.erased, sharePresence.erased,
            showCursors.erased, showSelections.erased, snapshotIntervalMinutes.erased, showCursorNames.erased,
            showCommentPins.erased, showResolvedPins.erased, pinsFollowFilter.erased, inspectUnit.erased, inspectScale.erased,
        ]
    }

    enum Automation {
        static let c = PreferenceCategory.automation
        static let highlightDataFields = PreferenceKey<Bool>("automation.highlight_data_fields", "Highlight data fields", category: c, scope: .local, default: true, control: .toggle, help: "data-merge")
        static let embedSampleRecords = PreferenceKey<Bool>("automation.embed_sample_records", "Embed sample records", category: c, default: true, control: .toggle, help: "data-merge")
        static let scriptConsoleOnError = PreferenceKey<Bool>("automation.script_console_on_error", "Show script console on error", category: c, scope: .local, default: true, control: .toggle, help: "scripting")

        static let all: [AnyPreferenceKey] = [highlightDataFields.erased, embedSampleRecords.erased, scriptConsoleOnError.erased]
    }

    enum Printing {
        static let warnMissingFonts = PreferenceKey<Bool>("printing.warn_missing_fonts", "Warn about missing fonts before printing", category: .printing, default: true, control: .toggle, help: "print-fonts")

        static let all: [AnyPreferenceKey] = [warnMissingFonts.erased]
    }

    enum Typeface {
        static let c = PreferenceCategory.typeface
        static let glyphCellSize = PreferenceKey<String>("typeface.glyph_cell_size", "Glyph cell size", category: c, default: "medium", control: choices([("small", "Small"), ("medium", "Medium"), ("large", "Large")]), help: "glyph-grid")
        static let snapToMetricLines = PreferenceKey<Bool>("typeface.snap_metric_lines", "Snap to metric lines", category: c, default: true, control: .toggle, help: "glyph-editing")
        static let previewText = PreferenceKey<String>("typeface.preview_text", "Font preview text", category: c, default: "Hamburgefonstiv", control: .text(placeholder: "Hamburgefonstiv"), help: "glyph-editing")
        static let showGeneratedFeatures = PreferenceKey<Bool>("typeface.show_generated_features", "Show generated features", category: c, default: true, control: .toggle, help: "opentype-features")

        static let all: [AnyPreferenceKey] = [glyphCellSize.erased, snapToMetricLines.erased, previewText.erased, showGeneratedFeatures.erased]
    }

    /// Every key, in page order.
    static let all: [AnyPreferenceKey] =
        General.all + Object.all + Text.all + Document.all + Import.all + Export.all + Spelling.all
        + Colors.all + Panels.all + Redraw.all + Sounds.all + Sync.all + Automation.all + Printing.all + Typeface.all

    static let byID: [String: AnyPreferenceKey] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func keys(in category: PreferenceCategory) -> [AnyPreferenceKey] {
        all.filter { $0.category == category }
    }
}
