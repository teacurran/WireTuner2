// swift-tools-version: 6.0
// WTRender: see docs/spec/client.adoc, "Packages".  Dependencies point strictly downward in that table.
import PackageDescription

let package = Package(
    name: "WTRender",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "WTRender", targets: ["WTRender"]),
    ],
    dependencies: [
        .package(path: "../WTGeometry"),
    ],
    targets: [
        .target(
            name: "WTRender",
            dependencies: [
                .product(name: "WTGeometry", package: "WTGeometry"),
            ],
            // Copied, not processed: MetalContext compiles this Metal Shading Language source at
            // run time.  Xcode 26 ships the offline Metal compiler as a separate download, and a
            // `.metal` file would make every SwiftPM and Xcode build depend on it.
            resources: [.copy("Shaders/TileShaders.msl")]
        ),
        .testTarget(
            name: "WTRenderTests",
            dependencies: ["WTRender"],
            // Golden PNGs are read by path from the source tree (ReferenceRenderTests), not
            // bundled, so `WTRENDER_RECORD_GOLDENS=1` can write them back in place.
            exclude: ["Goldens"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
