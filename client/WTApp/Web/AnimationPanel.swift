import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTRender

/// The Animation panel (WEB-017; animation.adoc, "Animation settings and preview"): the document's
/// settings -- *Frames from*, *Frame rate*, *Loop*, *Autoplay*, *Background*, each one change --
/// and the window's transport: first, step back, play or stop, step forward, last, the frame
/// counter and the scrubber.  Remote setting changes show at once (the body reads the state).
enum AnimationPanel {
    @MainActor
    static func descriptor(state: WebPanelState, features: WebFeatures) -> PanelDescriptor {
        PanelDescriptor(id: WebFeatures.animationPanel, title: "Animation", icon: "film.stack", defaultGroup: PanelCatalog.Group.navigation, menuOrder: 71,
                        helpSlug: "animation") {
            AnimationPanelBody(state: state)
        }
    }

    static let sources: [(FrameSource, String)] = [(.none, "None"), (.layers, "Layers"), (.pages, "Pages"), (.pagesAndLayers, "Pages and layers")]
    static let backgrounds: [(AnimationFrameBackground, String)] = [(.pageColor, "Page color"), (.white, "White"), (.transparent, "Transparent")]

    @MainActor
    static func source(_ window: DocumentWindowController) -> Binding<FrameSource> {
        Binding(get: { AnimationInfo(window.documentHandle.state).source }, set: { window.objectEditing.perform(SetAnimationSettings(source: $0)) })
    }

    @MainActor
    static func fps(_ window: DocumentWindowController) -> Binding<Double> {
        Binding(get: { AnimationInfo(window.documentHandle.state).fps }, set: { value in
            let clamped = min(max((value * 100).rounded() / 100, 0.01), 120)
            window.objectEditing.perform(SetAnimationSettings(fps: clamped))
        })
    }

    @MainActor
    static func loop(_ window: DocumentWindowController) -> Binding<Bool> {
        Binding(get: { AnimationInfo(window.documentHandle.state).loop }, set: { window.objectEditing.perform(SetAnimationSettings(loop: $0)) })
    }

    @MainActor
    static func autoplay(_ window: DocumentWindowController) -> Binding<Bool> {
        Binding(get: { AnimationInfo(window.documentHandle.state).autoplay }, set: { window.objectEditing.perform(SetAnimationSettings(autoplay: $0)) })
    }

    @MainActor
    static func background(_ window: DocumentWindowController) -> Binding<AnimationFrameBackground> {
        Binding(get: { AnimationFrameBackground.current(in: window.documentHandle.state) }, set: { window.objectEditing.perform(SetAnimationBackground($0)) })
    }

    /// The scrubber: the frame shown.
    @MainActor
    static func scrub(_ web: WindowWeb) -> Binding<Double> {
        Binding(get: { Double(web.frameIndex ?? 0) }, set: { web.show(Int($0.rounded())) })
    }

    /// The transport bar's buttons.
    enum Transport: CaseIterable {
        case first, back, play, forward, last, wholeDocument
    }

    @MainActor
    static func action(_ web: WindowWeb, _ transport: Transport) -> () -> Void { { run(transport, on: web) } }

    @MainActor
    static func run(_ transport: Transport, on web: WindowWeb) {
        switch transport {
        case .first: web.first()
        case .back: web.step(-1)
        case .play: web.togglePlay()
        case .forward: web.step(1)
        case .last: web.last()
        case .wholeDocument: web.endPreview()
        }
    }
}

struct AnimationPanelBody: View {
    let state: WebPanelState

    var body: some View {
        let _ = state.revision
        if let front = state.front {
            AnimationPanelContent(window: front.window, web: front.web)
        } else {
            Text("Open a document to set up its animation.").font(.callout).foregroundStyle(.secondary).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct AnimationPanelContent: View {
    let window: DocumentWindowController
    let web: WindowWeb

    var body: some View {
        let _ = web.revision
        let frames = web.frames
        VStack(alignment: .leading, spacing: 6) {
            Picker("Frames from", selection: AnimationPanel.source(window)) {
                ForEach(AnimationPanel.sources, id: \.0) { Text($0.1).tag($0.0) }
            }
            .accessibilityIdentifier("animation.source")
            HStack {
                Text("Frame rate")
                TextField("", value: AnimationPanel.fps(window), format: .number.precision(.fractionLength(0...2))).frame(width: 60)
                    .accessibilityIdentifier("animation.fps")
                Text("fps")
            }
            Toggle("Loop", isOn: AnimationPanel.loop(window)).accessibilityIdentifier("animation.loop")
            Toggle("Autoplay", isOn: AnimationPanel.autoplay(window)).accessibilityIdentifier("animation.autoplay")
            Picker("Background", selection: AnimationPanel.background(window)) {
                ForEach(AnimationPanel.backgrounds, id: \.0) { Text($0.1).tag($0.0) }
            }
            Divider()
            HStack(spacing: 4) {
                Button(action: AnimationPanel.action(web, .first)) { Image(systemName: "backward.end.fill") }.help("First frame")
                Button(action: AnimationPanel.action(web, .back)) { Image(systemName: "backward.frame.fill") }.help("Step backward")
                Button(action: AnimationPanel.action(web, .play)) { Image(systemName: web.isPlaying ? "stop.fill" : "play.fill") }
                    .help(web.isPlaying ? "Stop" : "Play").accessibilityIdentifier("animation.play")
                Button(action: AnimationPanel.action(web, .forward)) { Image(systemName: "forward.frame.fill") }.help("Step forward")
                Button(action: AnimationPanel.action(web, .last)) { Image(systemName: "forward.end.fill") }.help("Last frame")
                Spacer()
                Text(web.counter).monospacedDigit().accessibilityIdentifier("animation.counter")
            }
            .disabled(frames.isEmpty)
            if frames.count > 1 {
                Slider(value: AnimationPanel.scrub(web), in: 0...Double(frames.count - 1), step: 1).accessibilityIdentifier("animation.scrubber")
            }
            if web.frameIndex != nil {
                Button("Show Whole Document", action: AnimationPanel.action(web, .wholeDocument))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
