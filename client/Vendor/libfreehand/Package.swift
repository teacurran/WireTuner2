// swift-tools-version: 6.0
// libfreehand 0.1.4 and the part of librevenge 0.0.6 it needs (both MPL-2.0), built from source
// for the FreeHand importer (docs/spec/decisions.adoc D-083; import-formats.adoc, "FreeHand").
// `upstream/` is written by tools/freehand/vendor.sh from the pinned release tarballs plus the
// patches in tools/freehand/patches -- never edit it by hand; `bridge/` is WireTuner's (also
// MPL-2.0).  Third-party code: it lives outside client/Packages so the coverage gate and
// SonarQube, which read client/Packages/*/Sources, do not measure it.  Platform-neutral C++ with
// a C interface (include/CFreeHand.h): it builds wherever WTInterchange does, macOS and iOS
// (D-073), with no Boost, ICU or Little CMS and the SDK's zlib.
import PackageDescription

let package = Package(
    name: "libfreehand",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "CFreeHand", targets: ["CFreeHand"]),
    ],
    targets: [
        .target(
            name: "CFreeHand",
            exclude: [
                "upstream/libfreehand/COPYING", "upstream/libfreehand/AUTHORS",
                "upstream/librevenge/COPYING.MPL", "upstream/librevenge/AUTHORS",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("bridge/shim"),
                .headerSearchPath("upstream/libfreehand/inc"),
                .headerSearchPath("upstream/libfreehand/src/lib"),
                .headerSearchPath("upstream/librevenge/inc"),
                .headerSearchPath("upstream/librevenge/src/lib"),
                // librevenge's export macros: a static build, nothing exported.
                .define("LIBREVENGE_BUILD"),
                .define("LIBREVENGE_STREAM_BUILD"),
                .define("LIBREVENGE_GENERATORS_BUILD"),
                .define("NDEBUG"),
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
