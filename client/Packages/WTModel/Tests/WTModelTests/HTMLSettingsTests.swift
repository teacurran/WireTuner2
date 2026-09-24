import Foundation
import Testing
import WTCRDT
import WTInterchange
@testable import WTModel
import WTProto

/// WEB-007: HTML settings in the document model.
@Suite struct HTMLSettingsTests {
    @Test func aFreshDocumentReportsTheSynthesizedDefaultWithoutAnyElement() {
        let a = Replica(1)
        let settings = HTMLSettings(a.state)
        #expect(settings.isSynthesized)
        #expect(settings.settings == [.synthesizedDefault])
        #expect(settings.settings[0].settings == .defaults)
        #expect(a.state.store.elementOrder(WellKnown.settings, HTMLSettingsFields.settings).isEmpty)
        #expect(settings.selected(nil).id == nil)
        #expect(settings.selected(OpID(counter: 5, replica: 5)).name == "Default")
    }

    @Test func editingTheDefaultMaterializesItWithTheEditedFieldAndDefaultsForTheRest() throws {
        var a = Replica(1)
        var edited = HTMLPublishSettings.defaults
        edited.vectorFormat = .png
        edited.scale = 3
        let change = try a.perform(EditHTMLSetting(nil, settings: edited, options: [.vectorFormat]))!
        #expect(change.label == "Change HTML setting")
        let settings = HTMLSettings(a.state)
        #expect(!settings.isSynthesized)
        let setting = try #require(settings.settings.first)
        #expect(setting.id != nil && setting.name == "Default")
        #expect(setting.settings.vectorFormat == .png)
        // Only the edited field was written: scale reads its default.
        #expect(setting.settings.scale == 2 && setting.settings.imageQuality == 80)
        let stored = a.state.props(WellKnown.settings).settings.htmlSettings[0]
        #expect(stored.scale == 0 && stored.imageQuality == 0 && stored.vectorFormat == .png)
        // Undo removes the element and the Default is synthesized again.
        a.undo()
        #expect(HTMLSettings(a.state).isSynthesized)
    }

    @Test func addRenameEditAndDeleteAreOneChangeEachWithInverses() throws {
        var a = Replica(1)
        var email = HTMLPublishSettings(vectorFormat: .png, scale: 1, imageFormat: .png, background: .white, title: "News")
        email.fontMode = .system
        let add = try a.perform(AddHTMLSetting(name: "Email", settings: email))!
        #expect(add.label == "Add HTML setting")
        var settings = HTMLSettings(a.state)
        // Adding to a document with only the synthesized Default materializes it first.
        #expect(settings.settings.map(\.name) == ["Default", "Email"])
        #expect(settings.settings[1].settings == email)
        let id = try #require(settings.settings[1].id)
        #expect(try a.perform(RenameHTMLSetting(id, to: "Mail"))!.label == "Rename HTML setting")
        var changed = settings.settings[1].settings
        changed.imageQuality = 55
        changed.layout = .positionedObjects
        let edit = try a.perform(EditHTMLSetting(id, settings: changed, options: [.imageQuality, .layout]))!
        #expect(edit.ops.count == 1 && edit.ops[0].set.paths.count == 2)
        settings = HTMLSettings(a.state)
        #expect(settings.setting(id)?.name == "Mail")
        #expect(settings.setting(id)?.settings.imageQuality == 55 && settings.setting(id)?.settings.layout == .positionedObjects)
        #expect(try a.perform(DeleteHTMLSetting(id))!.label == "Delete HTML setting")
        #expect(HTMLSettings(a.state).settings.map(\.name) == ["Default"])
        a.undo()
        #expect(HTMLSettings(a.state).setting(id)?.settings.imageQuality == 55)
        a.undo()
        #expect(HTMLSettings(a.state).setting(id)?.settings.imageQuality == 80)
        a.undo()
        #expect(HTMLSettings(a.state).setting(id)?.name == "Email")
        a.undo()
        #expect(HTMLSettings(a.state).isSynthesized)
        #expect(try a.perform(EditHTMLSetting(nil, settings: .defaults, options: [])) == nil)
    }

    @Test func everyOptionRoundTripsThroughTheStoredMessage() throws {
        var a = Replica(1)
        let all = HTMLPublishSettings(layout: .positionedObjects, pageMode: .separateFiles, vectorFormat: .png, scale: 3, imageFormat: .webp,
                                      imageQuality: 42, fontMode: .outlines, animationStill: true, svgAnimationPosterOnly: true,
                                      allowScripts: true, background: .transparent, title: "Brochure")
        try a.perform(AddHTMLSetting(name: "All", settings: all))
        #expect(HTMLSettings(a.state).settings[1].settings == all)
        let id = try #require(HTMLSettings(a.state).settings[1].id)
        try a.perform(EditHTMLSetting(id, settings: .defaults, options: Set(HTMLSettingOption.allCases)))
        #expect(HTMLSettings(a.state).settings[1].settings == .defaults)
        for background in HTMLBackground.allCases {
            var value = HTMLPublishSettings.defaults
            value.background = background
            #expect(HTMLSettingInfo.settings(HTMLSettingInfo.stored(value)).background == background)
        }
    }

    @Test func refusals() throws {
        var a = Replica(1)
        #expect(throws: HTMLSettingsError.invalidValue("name")) { try a.perform(AddHTMLSetting(name: "  ")) }
        #expect(throws: HTMLSettingsError.invalidValue("name")) { try a.perform(AddHTMLSetting(name: String(repeating: "n", count: 65))) }
        #expect(throws: HTMLSettingsError.invalidValue("settings")) { try a.perform(AddHTMLSetting(name: "x", settings: HTMLPublishSettings(scale: 4))) }
        #expect(throws: HTMLSettingsError.invalidValue("settings")) {
            try a.perform(EditHTMLSetting(nil, settings: HTMLPublishSettings(imageQuality: 0), options: [.imageQuality]))
        }
        #expect(throws: HTMLSettingsError.invalidValue("settings")) {
            try a.perform(EditHTMLSetting(nil, settings: HTMLPublishSettings(title: String(repeating: "t", count: 257)), options: [.title]))
        }
        let missing = OpID(counter: 99, replica: 9)
        #expect(throws: HTMLSettingsError.unknownSetting(missing)) { try a.perform(RenameHTMLSetting(missing, to: "x")) }
        #expect(throws: HTMLSettingsError.unknownSetting(missing)) { try a.perform(EditHTMLSetting(missing, settings: .defaults, options: [.title])) }
        #expect(throws: HTMLSettingsError.unknownSetting(missing)) { try a.perform(DeleteHTMLSetting(missing)) }
        try a.perform(RenameHTMLSetting(nil, to: "Standard"))
        let settings = HTMLSettings(a.state)
        #expect(settings.settings.map(\.name) == ["Standard"])
        let first = try #require(settings.settings[0].id)
        #expect(throws: HTMLSettingsError.cannotDeleteDefault) { try a.perform(DeleteHTMLSetting(first)) }
    }

    @Test func duplicateNamesGetASuffixAtReadTime() throws {
        var pair = Pair()
        try pair.a.perform(AddHTMLSetting(name: "Web"))
        pair.sync()
        try pair.a.perform(AddHTMLSetting(name: "Phone"))
        try pair.b.perform(AddHTMLSetting(name: "Phone"))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let settings = HTMLSettings(pair.a.state)
        #expect(settings.settings.map(\.displayName) == ["Default", "Web", "Phone", "Phone (2)"])
        #expect(settings.settings.map(\.name) == ["Default", "Web", "Phone", "Phone"])
    }

    @Test func concurrentEditsToDifferentFieldsBothSurvive() throws {
        var pair = Pair()
        try pair.a.perform(AddHTMLSetting(name: "Web"))
        pair.sync()
        let id = try #require(HTMLSettings(pair.a.state).settings[1].id)
        var fonts = HTMLPublishSettings.defaults
        fonts.fontMode = .outlines
        var scale = HTMLPublishSettings.defaults
        scale.scale = 3
        try pair.a.perform(EditHTMLSetting(id, settings: fonts, options: [.fontMode]))
        try pair.b.perform(EditHTMLSetting(id, settings: scale, options: [.scale]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let merged = try #require(HTMLSettings(pair.b.state).setting(id)?.settings)
        #expect(merged.fontMode == .outlines && merged.scale == 3)
        // The same field resolves LWW: the greater OpId (B's) wins.
        var one = HTMLPublishSettings.defaults
        one.title = "A"
        var two = HTMLPublishSettings.defaults
        two.title = "B"
        try pair.a.perform(EditHTMLSetting(id, settings: one, options: [.title]))
        try pair.b.perform(EditHTMLSetting(id, settings: two, options: [.title]))
        pair.sync()
        #expect(HTMLSettings(pair.a.state).setting(id)?.settings.title == "B")
    }

    @Test func aSettingDeletedWhileEditedStaysDeletedWithTheEditRetained() throws {
        var pair = Pair()
        try pair.a.perform(AddHTMLSetting(name: "Web"))
        pair.sync()
        let id = try #require(HTMLSettings(pair.a.state).settings[1].id)
        try pair.a.perform(DeleteHTMLSetting(id))
        var png = HTMLPublishSettings.defaults
        png.vectorFormat = .png
        try pair.b.perform(EditHTMLSetting(id, settings: png, options: [.vectorFormat]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(HTMLSettings(pair.a.state).setting(id) == nil)
        try pair.a.perform(OpsCommand("Restore", ops: [Ops.elementDelete(WellKnown.settings, [HTMLSettingsFields.settings.element(id)], deleted: false)]))
        pair.sync()
        #expect(HTMLSettings(pair.b.state).setting(id)?.settings.vectorFormat == .png)
    }

    @Test func theLocalOnlyFieldsStayOnThisMac() throws {
        var pair = Pair()
        try pair.a.perform(AddHTMLSetting(name: "Web"))
        let id = try #require(HTMLSettings(pair.a.state).settings[1].id)
        try pair.a.perform(SetHTMLSettingLocation(id, to: "/Users/a/site"))
        try pair.a.perform(SetHTMLSettingLocation(nil, to: "/Users/a/default"))
        try pair.a.perform(SelectHTMLSetting(id))
        let settings = HTMLSettings(pair.a.state)
        #expect(settings.setting(id)?.location == "/Users/a/site")
        #expect(settings.settings[0].location == "/Users/a/default")
        #expect(settings.remembered == id && settings.selected.name == "Web")
        #expect(pair.a.core.undoStack.undo.count == 1)   // location and selection are view state: not undoable
        // Neither field is on the wire: the other replica sees the setting without them.
        for change in pair.a.sent {
            for op in change.ops {
                if case .set(let set) = op.op {
                    let paths = set.paths.map(RegisterPath.init)
                    #expect(!paths.contains(HTMLSettingsFields.location(id)) && !paths.contains(HTMLSettingsFields.selected))
                }
                if case .elementInsert(let insert) = op.op {
                    #expect(insert.values.settings.htmlSettings.allSatisfy { $0.location.isEmpty })
                }
            }
        }
        pair.sync()
        let theirs = HTMLSettings(pair.b.state)
        #expect(theirs.setting(id)?.location == "" && theirs.remembered == nil && theirs.selected.name == "Default")
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        // A setting added with a location keeps it here only; clearing the selection selects the first.
        try pair.a.perform(SelectHTMLSetting(nil))
        #expect(HTMLSettings(pair.a.state).selected.name == "Default")
        #expect(throws: HTMLSettingsError.unknownSetting(OpID(counter: 99, replica: 9))) {
            try pair.a.perform(SelectHTMLSetting(OpID(counter: 99, replica: 9)))
        }
        #expect(throws: HTMLSettingsError.invalidValue("location")) {
            try pair.a.perform(SetHTMLSettingLocation(id, to: String(repeating: "x", count: 4097)))
        }
    }

    @Test func settingTheDefaultsLocationMaterializesIt() throws {
        var a = Replica(1)
        try a.perform(SetHTMLSettingLocation(nil, to: "/Users/a/out"))
        let settings = HTMLSettings(a.state)
        #expect(!settings.isSynthesized && settings.settings[0].name == "Default" && settings.settings[0].location == "/Users/a/out")
        #expect(a.sent.count == 1 && a.sent[0].ops.count == 2 && a.sent[0].ops[1].noop == Wiretuner_Doc_V1_Noop())
    }

    @Test func concurrentMaterializationsOfTheDefaultKeepBoth() throws {
        var pair = Pair()
        var png = HTMLPublishSettings.defaults
        png.vectorFormat = .png
        try pair.a.perform(EditHTMLSetting(nil, settings: png, options: [.vectorFormat]))
        try pair.b.perform(RenameHTMLSetting(nil, to: "Standard"))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(Set(HTMLSettings(pair.a.state).settings.map(\.name)) == ["Default", "Standard"])
    }
}
