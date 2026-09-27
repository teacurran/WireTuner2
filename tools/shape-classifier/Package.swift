// swift-tools-version: 6.0
// The Select Similar shape classifier's training set, training and evaluation (selecting.adoc,
// "Select Similar"; IMG-030).  `swift run -c release shape-classifier all` regenerates the
// labelled fixture set, trains the model with Create ML on features from WTGeometry's
// `ShapeFeatures` (the app's own extraction), evaluates it on the fixture set and writes the model
// into the app's resources.  macOS only (Create ML).
import PackageDescription

let package = Package(
    name: "shape-classifier",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../client/Packages/WTGeometry"),
    ],
    targets: [
        .executableTarget(
            name: "shape-classifier",
            dependencies: [.product(name: "WTGeometry", package: "WTGeometry")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
