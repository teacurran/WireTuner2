#!/usr/bin/env bash
# Vendors zstd into client/Vendor/zstd, the C package WTCRDT (snapshots) and WTInterchange
# (Illustrator 2020 and later's private data) link (docs/spec/decisions.adoc D-098).
#
#     tools/zstd/vendor.sh            # rewrite client/Vendor/zstd/Sources/CZstd
#     tools/zstd/vendor.sh --check    # vendor into a scratch folder and diff it against the tree
#
# Reproducible: the release tarball is pinned by URL and SHA-256.  The library is upstream's own
# single-file build (build/single_file_libs/combine.py over lib/, as create_single_file_library.sh
# runs it) from upstream's zstd-in.c with two lines of settings changed -- no multithreading (no
# pthreads, no worker pool) and no dictionary builder (WireTuner trains no dictionaries; reading
# and writing with one is in the core library) -- plus lib/zstd.h, lib/zstd_errors.h and the
# LICENSE (zstd is BSD or GPLv2 at the user's choice; WireTuner takes it under BSD).  Needs
# python3 3.8 or later for combine.py.  Nothing is taken from Homebrew or the system.  Downloads
# are cached in ${WT_VENDOR_CACHE:-$TMPDIR/wt-vendor-cache}.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
package="$root/client/Vendor/zstd"
cache="${WT_VENDOR_CACHE:-${TMPDIR:-/tmp}/wt-vendor-cache}"

ZSTD_VERSION=1.5.7
ZSTD_URL="https://github.com/facebook/zstd/releases/download/v$ZSTD_VERSION/zstd-$ZSTD_VERSION.tar.gz"
ZSTD_SHA256=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3

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

# Writes the CZstd target's sources into $1 (which must not exist).
vendor_into() {
    local out="$1" work top libs
    work="$(mktemp -d "${TMPDIR:-/tmp}/wt-vendor.XXXXXX")"
    trap 'rm -rf "$work"' RETURN
    tar -xzf "$(fetch "$ZSTD_URL" "$ZSTD_SHA256")" -C "$work"
    top="$work/zstd-$ZSTD_VERSION"
    libs="$top/build/single_file_libs"
    # Upstream's template with multithreading and the dictionary builder left out; each edit must
    # match exactly once, so a new release that moves them fails here instead of vendoring wrong.
    [ "$(grep -c '^#define ZSTD_MULTITHREAD$' "$libs/zstd-in.c")" = 1 ] || die "zstd-in.c: ZSTD_MULTITHREAD line not found"
    [ "$(grep -c '^#include "dictBuilder/' "$libs/zstd-in.c")" = 4 ] || die "zstd-in.c: dictBuilder includes not found"
    sed -e 's|^#define ZSTD_MULTITHREAD$|/* single-threaded: no ZSTD_MULTITHREAD */|' \
        -e '/^#include "dictBuilder\//d' "$libs/zstd-in.c" > "$libs/wt-zstd-in.c"
    (cd "$libs" && python3 combine.py -r ../../lib -x legacy/zstd_legacy.h -o "$work/zstd.c" wt-zstd-in.c > "$work/combine.log" 2>&1) \
        || { cat "$work/combine.log" >&2; die "combine.py failed"; }
    mkdir -p "$out/include"
    cp "$work/zstd.c" "$out/zstd.c"
    cp "$top/lib/zstd.h" "$top/lib/zstd_errors.h" "$out/include/"
    cp "$top/LICENSE" "$out/LICENSE"
}

sources="$package/Sources/CZstd"
case "${1:-}" in
    "")
        rm -rf "$sources"
        vendor_into "$sources"
        echo "vendored zstd $ZSTD_VERSION into ${sources#"$root"/}"
        ;;
    --check)
        scratch="$(mktemp -d "${TMPDIR:-/tmp}/wt-vendor-check.XXXXXX")"
        trap 'rm -rf "$scratch"' EXIT
        vendor_into "$scratch/CZstd"
        diff -r "$scratch/CZstd" "$sources" > /dev/null || {
            diff -r "$scratch/CZstd" "$sources" | head -40 >&2
            die "client/Vendor/zstd differs from the pinned release; run tools/zstd/vendor.sh"
        }
        echo "client/Vendor/zstd matches zstd $ZSTD_VERSION"
        ;;
    *)
        die "unknown argument: $1"
        ;;
esac
