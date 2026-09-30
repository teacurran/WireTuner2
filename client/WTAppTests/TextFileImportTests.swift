import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
@testable import WireTuner

/// TYPE-008's app half (importing-text.adoc, "Importing a text file"): text files through the
/// Import panel and the import pointer, the *Encoding* option, and Finder drops.
@Suite(.serialized) @MainActor struct TextFileImportTests {
    /// An RTF file of "Hello" in bold 18 pt Helvetica.
    static func rtf(_ world: ImportWorld, _ name: String = "letter.rtf") throws -> URL {
        let text = NSAttributedString(string: "Hello", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 18)!])
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return world.files.write(name, data)
    }

    /// “Hi” in Windows-1252, no byte-order mark.
    static let windows1252 = Data([0x93, 0x48, 0x69, 0x94])

    @Test func theImportPanelOffersTextFilesAndTheirEncoding() throws {
        let world = ImportWorld()
        defer { world.close() }
        let panel = world.imports.makePanel()
        for type in [UTType.rtf, .rtfd, .plainText] { #expect(panel.allowedContentTypes.contains(type), "\(type)") }
        let accessory = try #require(world.imports.accessory)
        accessory.select(world.files.directory.appending(path: "a.txt"))
        #expect(accessory.textFormat == .plain && accessory.summary == "Plain Text" && !accessory.hasOptions)
        NSHostingView(rootView: ImportPanelAccessory(model: accessory)).layoutSubtreeIfNeeded()
        #expect(accessory.textEncoding == 0, "Automatic")
        accessory.textEncoding = 3
        #expect(world.imports.textEncodingChoice == 3 && ImportController.textEncodings[3].encoding == .macOSRoman)
        world.environment.preferences.defaults.set(99, forKey: ImportController.textEncodingKey)
        #expect(world.imports.textEncodingChoice == 0, "an unknown choice reads as Automatic")
        for (name, summary) in [("a.rtf", "Rich Text (RTF)"), ("a.rtfd", "Rich Text with Attachments (RTFD)"), ("a.md", "Markdown")] {
            accessory.select(world.files.directory.appending(path: name))
            #expect(accessory.summary == summary)
        }
        #expect(ImportController.isTextFile(world.files.directory.appending(path: "a.TXT")) && !ImportController.isTextFile(world.files.directory.appending(path: "a.svg")))
    }

    @Test func aClickMakesAnAutoExpandingBlockAndADragAFixedOne() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let letter = try Self.rtf(world)
        let clicked = await world.imports.place(letter, on: world.window, placement: .at(Point(x: 30, y: 40)))
        let block = try #require(clicked.placed.first)
        #expect(clicked.failures.isEmpty && world.state.textNode(block)?.string == "Hello")
        let props = world.state.props(block).text
        #expect(props.block.autoWidth && props.block.autoHeight && props.common.transform.tx == 30 && props.common.transform.ty == 40)
        #expect(world.window.selection.selection.ids.map(\.opID) == [block])
        #expect(world.document.undoTitle == "Undo Import text")
        let dragged = await world.imports.place(letter, on: world.window, placement: .fit(Rect(x: 100, y: 10, width: 120, height: 60), fillWidth: false))
        let fixed = world.state.props(try #require(dragged.placed.first)).text.block
        #expect(!fixed.autoWidth && fixed.width == 120 && fixed.height == 60)
        #expect(ImportController.textFrame(.at(Point(x: 1, y: 2))) == .point(Point(x: 1, y: 2)))
    }

    @Test func plainTextTakesTheGuessedOrTheChosenEncoding() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let file = world.files.write("quote.txt", Self.windows1252)
        let guessed = try #require(await world.imports.place([file], on: world.window, at: Point(x: 0, y: 0)).placed.first)
        #expect(world.state.textNode(guessed)?.string == "“Hi”")
        // The guess is the import summary: the block's note and the status bar.
        #expect(world.state.props(guessed).text.common.note.contains("(detected)"))
        #expect(world.window.statusBar.message.stringValue.contains("quote.txt: Encoding"))
        world.imports.textEncodingChoice = 3
        let roman = try #require(await world.imports.place([file], on: world.window, at: Point(x: 0, y: 50)).placed.first)
        #expect(world.state.textNode(roman)?.string == String(data: Self.windows1252, encoding: .macOSRoman))
        // A forced encoding the bytes do not decode in, and a file that is not what it says, are
        // named in the alert.
        world.imports.textEncodingChoice = 1
        let broken = world.files.write("broken.rtfd", Data("not a package".utf8))
        let refused = await world.imports.place([file, broken], on: world.window, at: nil)
        #expect(refused.placed.isEmpty && refused.failures.count == 2)
        #expect(world.alerts.last?.0 == "2 files could not be imported.")
        #expect(refused.failures[0].contains("quote.txt") && refused.failures[0].contains("UTF-8") && refused.failures[1].contains("broken.rtfd"))
        #expect(ImportController.failure(.unreadable(.rtf), name: "x.rtf").contains("readable Rich Text (RTF) file"))
    }

    @Test func aFinderDropPlacesTheTextAtThePointer() async throws {
        let world = ImportWorld(importFiles: true)
        defer { world.close() }
        let canvas = world.window.canvas
        _ = await world.window.documentHandle.openedModel()
        let notes = world.files.text("notes.md", "# Title\nBody")
        let location = NSPoint(x: 40, y: 60)
        #expect(canvas.performDragOperation(FileDragging([notes], at: location)))
        #expect(await eventually { world.objects.count == 1 })
        let block = world.objects[0]
        #expect(world.state.textNode(block)?.string == "# Title\nBody", "Markdown keeps its markup characters")
        let origin = canvas.viewport.toPasteboard(canvas.viewPoint(fromAppKit: canvas.convert(location, from: nil)))
        let transform = world.state.props(block).text.common.transform
        #expect(abs(transform.tx - origin.x) < 0.001 && abs(transform.ty - origin.y) < 0.001)
        #expect(world.state.props(block).text.block.autoWidth)
    }
}
