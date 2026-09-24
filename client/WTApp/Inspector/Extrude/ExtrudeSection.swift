import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import struct WTRender.StrokeStyle

/// The Object panel's extrusion pages (extrude.adoc, "Editing in the Object panel"; FX-021):
/// *Extrude* (length, vanishing point, position, rotation), *Surface* (kind, steps, ambient and two
/// lights, which apply only to *Shaded*) and *Profile* (kind, angle for *Static*, steps, twist, the
/// profile preview and btn:[Paste In]).  Values are read from the document on every render; each
/// edit is one `EditExtrusion` over every selected extrusion.
@MainActor
struct ExtrudeSectionModel {
    enum Page: String, CaseIterable, Identifiable {
        case extrude = "Extrude"
        case surface = "Surface"
        case profile = "Profile"

        var id: String { rawValue }
    }

    let document: DocumentHandle
    /// The selected extrusions.
    let nodes: [OpID]
    /// Where btn:[Paste In] reads.
    var pasteboard: any ObjectPasteboard

    static let surfaces: [(Wiretuner_Doc_V1_SurfaceKind, String)] = [
        (.flat, "Flat"), (.shaded, "Shaded"), (.wireframe, "Wireframe"), (.mesh, "Mesh"), (.hiddenMesh, "Hidden Mesh"),
    ]
    static let directions: [(Wiretuner_Doc_V1_LightDirection, String)] = [
        (.none, "None"), (.topLeft, "Top Left"), (.top, "Top"), (.topRight, "Top Right"), (.left, "Left"), (.front, "Front"), (.right, "Right"),
        (.bottomLeft, "Bottom Left"), (.bottom, "Bottom"), (.bottomRight, "Bottom Right"),
    ]
    static let profiles: [(Wiretuner_Doc_V1_ProfileKind, String)] = [(.none, "None"), (.bevel, "Bevel"), (.static, "Static")]
    nonisolated static let pasteRefusal = "Paste In takes one open path of two or more points: copy it first."

    /// The section when every selected object is an extrusion.
    init?(_ panel: ObjectPanelModel, pasteboard: any ObjectPasteboard = SystemObjectPasteboard()) {
        let objects = panel.objects
        guard !objects.isEmpty, objects.allSatisfy({ $0.object.kind == .extrude }) else { return nil }
        document = panel.document
        nodes = objects.map(\.id)
        self.pasteboard = pasteboard
    }

    private var props: [Wiretuner_Doc_V1_ExtrudeProps] { nodes.map { document.state.props($0).extrude } }
    private var first: Wiretuner_Doc_V1_ExtrudeProps { props[0] }

    /// The page the vanishing point and position are shown relative to (the pasteboard's origin
    /// without one).
    var origin: Point { document.currentPage.map { Point(x: $0.minX, y: $0.minY) } ?? .zero }
    var unit: MeasureUnit { document.units.measureUnit }

    // MARK: Extrude

    var length: Double? { shared(props.map(\.length)) }
    var vanishingX: Double? { shared(props.map { $0.vanishingPoint.x - origin.x }) }
    var vanishingY: Double? { shared(props.map { $0.vanishingPoint.y - origin.y }) }
    /// The object's centre on the page: the centre of the flat shape it extrudes.
    var positionX: Double? { shared(nodes.map { (ExtrudeTool.frontBounds($0, in: document)?.midX ?? 0) - origin.x }) }
    var positionY: Double? { shared(nodes.map { (ExtrudeTool.frontBounds($0, in: document)?.midY ?? 0) - origin.y }) }
    var z: Double? { shared(props.map(\.z)) }
    var rotationX: Double? { shared(props.map(\.rotation.x)) }
    var rotationY: Double? { shared(props.map(\.rotation.y)) }
    var rotationZ: Double? { shared(props.map(\.rotation.z)) }

    func edit(_ label: String, _ fields: [RegisterPath], _ build: (inout Wiretuner_Doc_V1_ExtrudeProps) -> Void) -> any WTModel.Command {
        EditExtrusion(nodes, label: label, fields: fields, build)
    }

    /// 0 ... 32,000 pt.
    func setLength(_ value: Double) -> any WTModel.Command { edit("Change depth", [ExtrudeFields.length]) { $0.length = min(max(value, 0), 32000) } }

    /// The vanishing point is one value (ATOMIC): the other coordinate is written as it is.
    func setVanishing(x: Double? = nil, y: Double? = nil) -> any WTModel.Command {
        let point = Point(x: x.map { $0 + origin.x } ?? first.vanishingPoint.x, y: y.map { $0 + origin.y } ?? first.vanishingPoint.y)
        return edit("Move vanishing point", [ExtrudeFields.vanishingPoint]) { $0.vanishingPoint = EffectEditorModel.point(point.x, point.y) }
    }

    func setVanishingX(_ value: Double) -> any WTModel.Command { setVanishing(x: value) }
    func setVanishingY(_ value: Double) -> any WTModel.Command { setVanishing(y: value) }

    /// *Position X* and *Y*: each extrusion moves so its centre is there (the vanishing point stays).
    func setPosition(x: Double? = nil, y: Double? = nil) -> (any WTModel.Command)? {
        let moves = nodes.compactMap { node -> (any WTModel.Command)? in
            guard let bounds = ExtrudeTool.frontBounds(node, in: document) else { return nil }
            let delta = Vector(dx: x.map { $0 + origin.x - bounds.midX } ?? 0, dy: y.map { $0 + origin.y - bounds.midY } ?? 0)
            return MoveObjects([node], by: delta)
        }
        return moves.isEmpty ? nil : CompositeCommand(Objects.label("Move", count: moves.count), moves)
    }

    func setPositionX(_ value: Double) -> (any WTModel.Command)? { setPosition(x: value) }
    func setPositionY(_ value: Double) -> (any WTModel.Command)? { setPosition(y: value) }

    func setZ(_ value: Double) -> any WTModel.Command { edit("Change position", [ExtrudeFields.z]) { $0.z = value } }

    /// The rotation is one value (ATOMIC): the other angles are written as they are.
    func setRotation(x: Double? = nil, y: Double? = nil, z: Double? = nil) -> any WTModel.Command {
        let current = first.rotation
        return edit("Rotate extrusion", [ExtrudeFields.rotation]) { props in
            props.rotation.x = x ?? current.x
            props.rotation.y = y ?? current.y
            props.rotation.z = z ?? current.z
        }
    }

    func setRotationX(_ value: Double) -> any WTModel.Command { setRotation(x: value) }
    func setRotationY(_ value: Double) -> any WTModel.Command { setRotation(y: value) }
    func setRotationZ(_ value: Double) -> any WTModel.Command { setRotation(z: value) }

    // MARK: Surface

    /// Unset reads Shaded.
    var surface: Wiretuner_Doc_V1_SurfaceKind? { shared(props.map { $0.surface.kind == .unspecified ? .shaded : $0.surface.kind }) }
    /// 0 reads 10.
    var surfaceSteps: Double? { shared(props.map { Double($0.surface.steps == 0 ? 10 : $0.surface.steps) }) }
    var ambient: Double? { shared(props.map { Double($0.surface.ambient) }) }
    /// Lights apply only to the Shaded surface.
    var lightsApply: Bool { surface == .shaded }

    func light(_ second: Bool) -> [Wiretuner_Doc_V1_Light] { props.map { second ? $0.surface.light2 : $0.surface.light1 } }
    func direction(_ second: Bool) -> Wiretuner_Doc_V1_LightDirection? { shared(light(second).map { $0.direction == .unspecified ? .none : $0.direction }) }
    func intensity(_ second: Bool) -> Double? { shared(light(second).map { Double($0.intensity) }) }

    func setSurface(_ kind: Wiretuner_Doc_V1_SurfaceKind) -> any WTModel.Command { edit("Change surface", [ExtrudeFields.surfaceKind]) { $0.surface.kind = kind } }

    /// 1 ... 100.
    func setSurfaceSteps(_ value: Double) -> any WTModel.Command {
        edit("Change steps", [ExtrudeFields.surfaceSteps]) { $0.surface.steps = UInt32(min(max(value.rounded(), 1), 100)) }
    }

    /// 0 ... 100.
    func setAmbient(_ value: Double) -> any WTModel.Command {
        edit("Change ambient", [ExtrudeFields.ambient]) { $0.surface.ambient = UInt32(min(max(value.rounded(), 0), 100)) }
    }

    func setDirection(_ direction: Wiretuner_Doc_V1_LightDirection, second: Bool) -> any WTModel.Command {
        let field = (second ? ExtrudeFields.light2 : ExtrudeFields.light1).child(1)
        return edit("Change light", [field]) { props in
            if second { props.surface.light2.direction = direction } else { props.surface.light1.direction = direction }
        }
    }

    /// The light pop-up and field of light 1 or 2 (`second`).
    func directionSetter(second: Bool) -> (Wiretuner_Doc_V1_LightDirection) -> any WTModel.Command {
        { setDirection($0, second: second) }
    }

    func intensitySetter(second: Bool) -> (Double) -> any WTModel.Command {
        { setIntensity($0, second: second) }
    }

    /// 0 ... 100.
    func setIntensity(_ value: Double, second: Bool) -> any WTModel.Command {
        let field = (second ? ExtrudeFields.light2 : ExtrudeFields.light1).child(2)
        let intensity = UInt32(min(max(value.rounded(), 0), 100))
        return edit("Change light", [field]) { props in
            if second { props.surface.light2.intensity = intensity } else { props.surface.light1.intensity = intensity }
        }
    }

    // MARK: Profile

    var profile: Wiretuner_Doc_V1_ProfileKind? { shared(props.map { $0.profile.kind == .unspecified ? .none : $0.profile.kind }) }
    var profileAngle: Double? { shared(props.map(\.profile.angle)) }
    /// 0 reads 1.
    var profileSteps: Double? { shared(props.map { Double(max($0.profile.steps, 1)) }) }
    var twist: Double? { shared(props.map(\.profile.twist)) }
    /// *Angle* applies to Static only.
    var angleApplies: Bool { profile == .static }

    func setProfile(_ kind: Wiretuner_Doc_V1_ProfileKind) -> any WTModel.Command { edit("Change profile", [ExtrudeFields.profileKind]) { $0.profile.kind = kind } }
    func setProfileAngle(_ value: Double) -> any WTModel.Command { edit("Change profile angle", [ExtrudeFields.profileAngle]) { $0.profile.angle = value } }

    /// 1 ... 100.
    func setProfileSteps(_ value: Double) -> any WTModel.Command {
        edit("Change profile steps", [ExtrudeFields.profileSteps]) { $0.profile.steps = UInt32(min(max(value.rounded(), 1), 100)) }
    }

    func setTwist(_ value: Double) -> any WTModel.Command { edit("Change twist", [ExtrudeFields.twist]) { $0.profile.twist = value } }

    /// btn:[Paste In]: the pasteboard's one open path becomes the profile, or the refusal to show.
    func pasteProfile() -> Result<any WTModel.Command, PasteProfileRefusal> {
        guard let bytes = pasteboard.read(), let payload = ClipboardPayload(decoding: bytes), payload.nodes.count == 1,
              let contour = PasteExtrudeProfile.profile(from: payload.nodes[0].props.path) else { return .failure(PasteProfileRefusal()) }
        return .success(PasteExtrudeProfile(nodes, contour: contour))
    }

    /// The *Profile preview* box: the first extrusion's profile path, fitted.
    var profilePreview: CGImage? {
        guard first.profile.hasPath, first.profile.path.points.count >= 2 else { return nil }
        let path = Appearances.display([first.profile.path])
        guard let bounds = path.controlBounds else { return nil }
        let size = Size(width: 64, height: 48)
        let scale = min(56 / max(bounds.width, 1), 40 / max(bounds.height, 1))
        let transform = AffineTransform.translation(x: -bounds.midX, y: -bounds.midY).concatenating(.scale(x: scale, y: scale))
            .concatenating(.translation(x: size.width / 2, y: size.height / 2))
        let item = PathItem(path: path, appearance: Appearance([.stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 1)))]),
                            transform: transform)
        return AttributePreview.render(.path(item), size: size)
    }

    func committing<Value>(_ command: @escaping (Value) -> (any WTModel.Command)?) -> (Value) -> Void {
        { [document] value in if let command = command(value) { document.perform(command) } }
    }
}

/// Paste In's refusal.
struct PasteProfileRefusal: Error, Equatable {
    var message: String { ExtrudeSectionModel.pasteRefusal }
}

struct ExtrudeSectionView: View {
    let model: ExtrudeSectionModel
    @State private var page: ExtrudeSectionModel.Page
    @State private var message: String?

    init(model: ExtrudeSectionModel, page: ExtrudeSectionModel.Page = .extrude) {
        self.model = model
        _page = State(initialValue: page)
    }

    /// btn:[Paste In]: performs the paste, or returns the refusal to show.
    static func paste(_ model: ExtrudeSectionModel) -> String? {
        switch model.pasteProfile() {
        case .success(let command):
            model.document.perform(command)
            return nil
        case .failure(let refusal):
            return refusal.message
        }
    }

    private func paste() { message = Self.paste(model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Page", selection: $page) {
                ForEach(ExtrudeSectionModel.Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("object.extrude.page")
            Form {
                switch page {
                case .extrude: Self.extrude(model)
                case .surface: Self.surface(model)
                case .profile: profile
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder static func extrude(_ model: ExtrudeSectionModel) -> some View {
        CommitField(title: "Length", value: model.length, identifier: "object.extrude.length", commit: model.committing(model.setLength))
        MeasureField(title: "Vanishing point X", value: model.vanishingX, unit: model.unit, identifier: "object.extrude.vp-x", commit: model.committing(model.setVanishingX))
        MeasureField(title: "Vanishing point Y", value: model.vanishingY, unit: model.unit, identifier: "object.extrude.vp-y", commit: model.committing(model.setVanishingY))
        MeasureField(title: "Position X", value: model.positionX, unit: model.unit, identifier: "object.extrude.x", commit: model.committing(model.setPositionX))
        MeasureField(title: "Position Y", value: model.positionY, unit: model.unit, identifier: "object.extrude.y", commit: model.committing(model.setPositionY))
        MeasureField(title: "Position Z", value: model.z, unit: model.unit, identifier: "object.extrude.z", commit: model.committing(model.setZ))
        CommitField(title: "Rotation X", value: model.rotationX, identifier: "object.extrude.rotation-x", commit: model.committing(model.setRotationX))
        CommitField(title: "Rotation Y", value: model.rotationY, identifier: "object.extrude.rotation-y", commit: model.committing(model.setRotationY))
        CommitField(title: "Rotation Z", value: model.rotationZ, identifier: "object.extrude.rotation-z", commit: model.committing(model.setRotationZ))
    }

    @ViewBuilder static func surface(_ model: ExtrudeSectionModel) -> some View {
        AttributePicker(title: "Surface", value: model.surface, choices: ExtrudeSectionModel.surfaces, identifier: "object.extrude.surface",
                        commit: model.committing(model.setSurface))
        CommitField(title: "Steps", value: model.surfaceSteps, identifier: "object.extrude.steps", commit: model.committing(model.setSurfaceSteps))
        Group {
            CommitField(title: "Ambient", value: model.ambient, identifier: "object.extrude.ambient", commit: model.committing(model.setAmbient))
            ForEach([false, true], id: \.self) { second in
                AttributePicker(title: second ? "Light 2" : "Light 1", value: model.direction(second), choices: ExtrudeSectionModel.directions,
                                identifier: "object.extrude.light\(second ? 2 : 1)", commit: model.committing(model.directionSetter(second: second)))
                CommitField(title: "Intensity", value: model.intensity(second), identifier: "object.extrude.intensity\(second ? 2 : 1)",
                            commit: model.committing(model.intensitySetter(second: second)))
            }
        }
        .disabled(!model.lightsApply)
    }

    @ViewBuilder private var profile: some View {
        AttributePicker(title: "Profile", value: model.profile, choices: ExtrudeSectionModel.profiles, identifier: "object.extrude.profile",
                        commit: model.committing(model.setProfile))
        CommitField(title: "Angle", value: model.profileAngle, identifier: "object.extrude.angle", commit: model.committing(model.setProfileAngle))
            .disabled(!model.angleApplies)
        CommitField(title: "Steps", value: model.profileSteps, identifier: "object.extrude.profile-steps", commit: model.committing(model.setProfileSteps))
        CommitField(title: "Twist", value: model.twist, identifier: "object.extrude.twist", commit: model.committing(model.setTwist))
        HStack {
            AttributePreviewImage(image: model.profilePreview, size: Size(width: 64, height: 48), identifier: "object.extrude.preview")
            Button("Paste In", action: paste).accessibilityIdentifier("object.extrude.paste")
        }
        if let message {
            Text(message).font(.caption).foregroundStyle(.red).accessibilityIdentifier("object.extrude.message")
        }
    }
}
