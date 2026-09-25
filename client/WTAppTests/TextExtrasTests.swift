import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTText
@testable import WireTuner

/// DOC-024's substitution badge in the Character section.
@Suite(.serialized) @MainActor struct TextExtrasTests {
    @Test func theCharacterSectionBadgesAMissingFamily() async throws {
        let document = DocumentHandle.memory(title: "Fonts")
        let text = try #require(await document.addText("Hello"))
        let selection = Selection([SelectionID(text)])
        let model = ObjectPanelModel(document: document, selection: selection)
        let installed = try #require(model.text)
        #expect(model.substitute(for: installed) == nil, "the default family is installed")
        let missing = FontDocuments.missing()
        _ = await model.setFontFamily(missing)?.value
        await document.settle()
        let section = try #require(ObjectPanelModel(document: document, selection: selection).text)
        #expect(section.family == missing)
        let substitute = try #require(model.substitute(for: section))
        #expect(!substitute.family.isEmpty && substitute.family != missing)
        #expect(FontSubstitutionBadge.text(family: missing, substitute: FaceName(family: "Helvetica Neue")) == "[\(missing)] drawn in Helvetica Neue")
        PanelRendering.host(TextSectionView(section: section, model: model))
        PanelRendering.host(FontSubstitutionBadge(family: nil, substitute: nil))
        // Mixed families: no badge.
        #expect(model.substitute(for: ObjectPanelModel.TextSection(nodes: [], editing: false, family: nil, style: nil, size: nil, alignment: nil)) == nil)
    }
}
