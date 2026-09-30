#!/usr/bin/env bash
# Vendors libfreehand and the part of librevenge it needs into client/Vendor/libfreehand, the
# C++ package the FreeHand importer links (docs/spec/decisions.adoc D-083; import-formats.adoc,
# "FreeHand"; IO-041).
#
#     tools/freehand/vendor.sh            # rewrite client/Vendor/libfreehand/Sources/CFreeHand/upstream
#     tools/freehand/vendor.sh --check    # vendor into a scratch folder and diff it against the tree
#     tools/freehand/vendor.sh --archive OUT.tar.gz
#                                         # the MPL-covered sources as shipped (upstream + patches +
#                                         # bridge), for publishing beside a release (MPL-2.0 s. 3.2)
#
# Reproducible: the two release tarballs are pinned by URL and SHA-256, only the files the
# importer compiles are copied, and the patches in tools/freehand/patches are applied in name
# order with `patch -p1` from the upstream folder.  Nothing is taken from Homebrew or the
# system: Boost, ICU and Little CMS are not used (the patches replace their few uses; the bridge
# supplies the two ICU macros libfreehand needs), and zlib is the SDK's.  Downloads are cached
# in ${WT_VENDOR_CACHE:-$TMPDIR/wt-vendor-cache}.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
package="$root/client/Vendor/libfreehand"
patches="$root/tools/freehand/patches"
cache="${WT_VENDOR_CACHE:-${TMPDIR:-/tmp}/wt-vendor-cache}"

LIBFREEHAND_VERSION=0.1.4
LIBFREEHAND_URL="https://dev-www.libreoffice.org/src/libfreehand/libfreehand-$LIBFREEHAND_VERSION.tar.xz"
LIBFREEHAND_SHA256=350b10d24a76d7e8c8ae98b74c2d432a2c8ddec08935d09856d20b695a35e600
LIBREVENGE_VERSION=0.0.6
LIBREVENGE_URL="https://downloads.sourceforge.net/project/libwpd/librevenge/librevenge-$LIBREVENGE_VERSION/librevenge-$LIBREVENGE_VERSION.tar.xz"
LIBREVENGE_SHA256=19eacf5ce55d7fe6a990a45142589cdf7da0c7b68701797f133482cb44f189fa

# The files compiled into CFreeHand, relative to each release's top folder.
LIBFREEHAND_FILES=(
    COPYING AUTHORS
    inc/libfreehand/libfreehand.h inc/libfreehand/FreeHandDocument.h
    src/lib/FHCollector.cpp src/lib/FHCollector.h src/lib/FHConstants.h
    src/lib/FHInternalStream.cpp src/lib/FHInternalStream.h
    src/lib/FHParser.cpp src/lib/FHParser.h
    src/lib/FHPath.cpp src/lib/FHPath.h
    src/lib/FHTransform.cpp src/lib/FHTransform.h src/lib/FHTypes.h
    src/lib/FreeHandDocument.cpp
    src/lib/libfreehand_utils.cpp src/lib/libfreehand_utils.h
    src/lib/tokenhash.h src/lib/tokens.h
)
LIBREVENGE_FILES=(
    COPYING.MPL AUTHORS
    inc/librevenge/librevenge.h inc/librevenge/librevenge-api.h
    inc/librevenge/RVNGBinaryData.h inc/librevenge/RVNGDrawingInterface.h
    inc/librevenge/RVNGPresentationInterface.h inc/librevenge/RVNGProperty.h
    inc/librevenge/RVNGPropertyList.h inc/librevenge/RVNGPropertyListVector.h
    inc/librevenge/RVNGSpreadsheetInterface.h inc/librevenge/RVNGString.h
    inc/librevenge/RVNGStringVector.h inc/librevenge/RVNGSVGDrawingGenerator.h
    inc/librevenge/RVNGTextInterface.h
    inc/librevenge-stream/librevenge-stream.h inc/librevenge-stream/librevenge-stream-api.h
    inc/librevenge-stream/RVNGStream.h inc/librevenge-stream/RVNGStreamImplementation.h
    inc/librevenge-stream/RVNGDirectoryStream.h
    inc/librevenge-generators/librevenge-generators.h inc/librevenge-generators/librevenge-generators-api.h
    inc/librevenge-generators/RVNGCSVSpreadsheetGenerator.h inc/librevenge-generators/RVNGHTMLTextGenerator.h
    inc/librevenge-generators/RVNGRawDrawingGenerator.h inc/librevenge-generators/RVNGRawPresentationGenerator.h
    inc/librevenge-generators/RVNGRawSpreadsheetGenerator.h inc/librevenge-generators/RVNGRawTextGenerator.h
    inc/librevenge-generators/RVNGSVGPresentationGenerator.h inc/librevenge-generators/RVNGTextDrawingGenerator.h
    inc/librevenge-generators/RVNGTextPresentationGenerator.h inc/librevenge-generators/RVNGTextSpreadsheetGenerator.h
    inc/librevenge-generators/RVNGTextTextGenerator.h
    src/lib/librevenge_internal.h
    src/lib/RVNGBinaryData.cpp src/lib/RVNGMemoryStream.cpp src/lib/RVNGMemoryStream.h
    src/lib/RVNGProperty.cpp src/lib/RVNGPropertyList.cpp src/lib/RVNGPropertyListVector.cpp
    src/lib/RVNGString.cpp src/lib/RVNGStringVector.cpp src/lib/RVNGSVGDrawingGenerator.cpp
)

die() { echo "vendor.sh: $*" >&2; exit 1; }

fetch() { # url sha256 -> path of the verified tarball
    local url="$1" sum="$2" file
    file="$cache/$(basename "$url")"
    mkdir -p "$cache"
    if [ ! -f "$file" ] || [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sum" ]; then
        curl -fsSL --retry 3 -o "$file.part" "$url" || die "download failed: $url"
        mv "$file.part" "$file"
    fi
    [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sum" ] || die "SHA-256 mismatch for $url"
    echo "$file"
}

# Writes the patched upstream tree into $1 (which must not exist).
vendor_into() {
    local out="$1" work
    work="$(mktemp -d "${TMPDIR:-/tmp}/wt-vendor.XXXXXX")"
    trap 'rm -rf "$work"' RETURN
    tar -xJf "$(fetch "$LIBFREEHAND_URL" "$LIBFREEHAND_SHA256")" -C "$work"
    tar -xJf "$(fetch "$LIBREVENGE_URL" "$LIBREVENGE_SHA256")" -C "$work"
    mkdir -p "$out/libfreehand" "$out/librevenge"
    for file in "${LIBFREEHAND_FILES[@]}"; do
        mkdir -p "$out/libfreehand/$(dirname "$file")"
        cp "$work/libfreehand-$LIBFREEHAND_VERSION/$file" "$out/libfreehand/$file"
    done
    for file in "${LIBREVENGE_FILES[@]}"; do
        mkdir -p "$out/librevenge/$(dirname "$file")"
        cp "$work/librevenge-$LIBREVENGE_VERSION/$file" "$out/librevenge/$file"
    done
    local patch
    for patch in "$patches"/*.patch; do
        [ -e "$patch" ] || continue
        (cd "$out" && patch -p1 --quiet --no-backup-if-mismatch < "$patch") || die "patch failed: $(basename "$patch")"
    done
}

upstream="$package/Sources/CFreeHand/upstream"
case "${1:-}" in
    "")
        rm -rf "$upstream"
        vendor_into "$upstream"
        echo "vendored libfreehand $LIBFREEHAND_VERSION and librevenge $LIBREVENGE_VERSION into ${upstream#"$root"/}"
        ;;
    --check)
        scratch="$(mktemp -d "${TMPDIR:-/tmp}/wt-vendor-check.XXXXXX")"
        trap 'rm -rf "$scratch"' EXIT
        vendor_into "$scratch/upstream"
        diff -ru "$scratch/upstream" "$upstream" || die "client/Vendor/libfreehand differs from the pinned releases plus patches; run tools/freehand/vendor.sh"
        echo "client/Vendor/libfreehand matches libfreehand $LIBFREEHAND_VERSION + librevenge $LIBREVENGE_VERSION + patches"
        ;;
    --archive)
        [ -n "${2:-}" ] || die "--archive needs an output path"
        out="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
        (cd "$root" && tar -czf "$out" client/Vendor/libfreehand tools/freehand)
        echo "wrote $out"
        ;;
    *)
        die "unknown argument: $1"
        ;;
esac
