import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// What the print pipeline adds to the renderer (PRINT-006, PRINT-010's render half): object
/// screens assigned through groups by member node, the job's flatness and per-path overrides,
/// and the vector-output renderer the print context draws with.
@Suite struct PrintOutputRenderTests {
    static let inch = Rect(x: 0, y: 0, width: 72, height: 72)
    static let group = NodeID(counter: 1, replica: 1)
    static let member = NodeID(counter: 2, replica: 1)
    static let plain = NodeID(counter: 3, replica: 1)

    static func square(_ rect: Rect, black: Double = 0.5) -> DisplayItem {
        .path(PathItem(path: DisplayPath(rect: rect), appearance: Appearance([.fill(FillPaint(paint: .solid(Color(cyan: 0, magenta: 0, yellow: 0, black: black))))])))
    }

    static func screen(_ list: DisplayList, nested: [[Int]: NodeID], screens: [NodeID: HalftoneScreen], plate: HalftoneScreen) throws -> BitPlate {
        try Screener(resolution: 300, bandHeight: 128).screenPlate(list, plate: .black, renderer: PlateRenderer(), page: inch, plateScreen: plate,
                                                                   objectScreens: screens, nestedNodeIDs: nested)
    }

    /// A member's own screen wins over its group's; members without one take the group's; the
    /// rest of the plate keeps the plate's.
    @Test func memberScreensResolveThroughGroups() throws {
        let left = Rect(x: 0, y: 0, width: 36, height: 72), right = Rect(x: 36, y: 0, width: 36, height: 72)
        let grouped = DisplayItem.group(GroupItem(children: [Self.square(left), Self.square(right)]))
        let list = DisplayList(canvas: "print", items: [grouped], nodeIDs: [Self.group])
        let nested: [[Int]: NodeID] = [[0, 0]: Self.member, [0, 1]: Self.plain]
        let plate = HalftoneScreen(shape: .round, angle: 45, frequency: 30)
        let groupScreen = HalftoneScreen(shape: .line, angle: 75, frequency: 30)
        let memberScreen = HalftoneScreen(shape: .round, angle: 15, frequency: 30)
        let mixed = try Self.screen(list, nested: nested, screens: [Self.group: groupScreen, Self.member: memberScreen], plate: plate)
        let whole = DisplayList(canvas: "print", items: [Self.square(Self.inch)])
        let at15 = try Self.screen(whole, nested: [:], screens: [:], plate: memberScreen)
        let at75 = try Self.screen(whole, nested: [:], screens: [:], plate: groupScreen)
        let split = Int(36 * 300 / 72.0)
        var wrong = 0
        for y in 0..<mixed.height {
            for x in 0..<mixed.width where x != split - 1 && x != split {
                let expected = x < split ? at15.isInked(x: x, y: y) : at75.isInked(x: x, y: y)
                if mixed.isInked(x: x, y: y) != expected { wrong += 1 }
            }
        }
        #expect(wrong == 0)
        // Nested ids alone (no top-level ids) still assign; a member's screen equal to the plate's
        // and no other screen leaves the whole plate at the plate's screen.
        let bare = DisplayList(canvas: "print", items: [grouped])
        #expect(ScreenAssignment(bare, plateScreen: plate, objectScreens: [Self.member: memberScreen], nestedNodeIDs: nested) != nil)
        #expect(ScreenAssignment(bare, plateScreen: plate, objectScreens: [Self.member: plate], nestedNodeIDs: nested) == nil)
        #expect(ScreenAssignment(bare, plateScreen: plate, objectScreens: [Self.member: memberScreen]) == nil)
    }

    /// At most 256 screens: objects past the 255th distinct screen take their group's (or the
    /// plate's).
    @Test func screensStopAtTwoHundredFiftySix() {
        var items: [DisplayItem] = []
        var ids: [NodeID?] = []
        var screens: [NodeID: HalftoneScreen] = [:]
        for index in 0..<300 {
            let node = NodeID(counter: UInt64(100 + index), replica: 1)
            items.append(Self.square(Rect(x: Double(index % 72), y: 0, width: 1, height: 1)))
            ids.append(node)
            screens[node] = HalftoneScreen(shape: .round, angle: Double(index) / 2, frequency: 30)
        }
        let assignment = ScreenAssignment(DisplayList(canvas: "print", items: items, nodeIDs: ids), plateScreen: HalftoneScreen(angle: 200, frequency: 31),
                                          objectScreens: screens)
        #expect(assignment?.screens.count == 256)
    }

    /// The job's flatness replaces the tolerance on the context; a path's own flatness applies
    /// around that path, nested overrides inside an overridden group included.
    @Test func flatnessOverridesDrawTheSameShapes() {
        let curve = DisplayItem.path(PathItem(path: DisplayPath(ellipseIn: Rect(x: 4, y: 4, width: 60, height: 60)),
                                              appearance: Appearance([.fill(FillPaint(paint: .solid(.black)))])))
        let list = DisplayList(canvas: "print", items: [curve, .group(GroupItem(children: [curve]))])
        var renderer = CoreGraphicsRenderer(background: .white)
        let reference = renderer.renderBitmap(list, viewport: Viewport(size: Size(width: 72, height: 72)))!
        renderer.outputFlatness = 0.1
        renderer.flatnessOverrides = [[0]: 0.2, [1]: 0.3, [1, 0]: 0.1]
        let overridden = renderer.renderBitmap(list, viewport: Viewport(size: Size(width: 72, height: 72)))!
        #expect(reference.width == overridden.width)
        let a = BitmapSurface.pixels(reference), b = BitmapSurface.pixels(overridden)
        #expect(zip(a, b).filter { abs(Int($0) - Int($1)) > 64 }.count < a.count / 100)
    }

    /// The vector-output renderer keeps its settings but never proofs and places raster work at
    /// the given scale.
    @Test func vectorOutputRendererIsConfigured() {
        var renderer = CoreGraphicsRenderer()
        renderer.colorManagement.proof = WTColor.ProofSetup(profile: TestPresses.light)
        let vector = renderer.forVectorOutput(rasterScale: 3)
        #expect(vector.vectorOutput && vector.rasterScale == 3 && vector.colorManagement.proof == nil)
        #expect(renderer.forVectorOutput(rasterScale: .nan).rasterScale == 1)
        #expect(renderer.forVectorOutput().rasterScale == CoreGraphicsRenderer.pdfRasterScale)
    }
}

extension BitmapSurface {
    /// The RGBA bytes of `image` drawn on white.
    static func pixels(_ image: CGImage) -> [UInt8] {
        let surface = BitmapSurface(width: image.width, height: image.height)!
        surface.context.setFillColor(CGColor(gray: 1, alpha: 1))
        surface.context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        surface.context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let base = surface.context.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: base, count: surface.context.bytesPerRow * image.height))
    }
}
