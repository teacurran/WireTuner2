#!/usr/bin/env bash
# Builds the protoc plugins that buf.gen.yaml runs as `local` plugins into tools/bin/
# (gitignored).  Today that is one: protoc-gen-grpc-swift-2 from grpc/grpc-swift-protobuf, the
# grpc-swift 2 (async/await, GRPCCore) stub generator.  The BSR's buf.build/grpc/swift is a
# grpc-swift 1.x generator (v1.27.6 as of 2026-09; see docs/spec/decisions.adoc D-014), so the
# plugin is built from source, pinned to the grpc-swift-protobuf release the client already
# resolves in client/Packages/WTProto/Package.resolved: stubs and runtime move together.
#
#     tools/proto/install-plugins.sh            # builds if tools/bin lacks the pinned version
#     tools/proto/install-plugins.sh --force    # rebuilds regardless
#     GRPC_SWIFT_PROTOBUF_VERSION=2.4.1 tools/proto/install-plugins.sh   # override the pin
#
# Needs git and a Swift 6 toolchain (Xcode 26 on macOS; swift.org toolchain on Linux, where the
# binary is built with the Swift standard library linked statically so a cached copy runs on a
# machine without the toolchain).  The proto workflow caches tools/bin by this script's hash.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
bin="$root/tools/bin"
resolved="$root/client/Packages/WTProto/Package.resolved"
plugin="protoc-gen-grpc-swift-2"
repository="https://github.com/grpc/grpc-swift-protobuf"
force=false

for argument in "$@"; do
    case "$argument" in
        --force) force=true ;;
        *) echo "unknown argument: $argument" >&2; exit 2 ;;
    esac
done

# The pin: the grpc-swift-protobuf version in WTProto's Package.resolved unless overridden.
version="${GRPC_SWIFT_PROTOBUF_VERSION:-}"
if [ -z "$version" ]; then
    version="$(awk '/"identity" : "grpc-swift-protobuf"/ { found = 1 }
                    found && /"version"/ { gsub(/[",]/, "", $3); print $3; exit }' "$resolved")"
fi
if [ -z "$version" ]; then
    echo "install-plugins: cannot find grpc-swift-protobuf in $resolved; set GRPC_SWIFT_PROTOBUF_VERSION" >&2
    exit 2
fi

mkdir -p "$bin"

if [ "$force" = false ] && [ -x "$bin/$plugin" ]; then
    installed="$("$bin/$plugin" --version 2>/dev/null || true)"
    if [ "$installed" = "$plugin $version" ]; then
        echo "install-plugins: $installed already in $bin"
        exit 0
    fi
fi

for tool in git swift; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "install-plugins: $tool is not installed" >&2
        exit 2
    fi
done

source_dir="$bin/src/grpc-swift-protobuf-$version"
rm -rf "$source_dir"
mkdir -p "$(dirname "$source_dir")"
echo "==> git clone $repository@$version"
git clone --quiet --depth 1 --branch "$version" "$repository" "$source_dir"

build_flags=(-c release --product "$plugin")
if [ "$(uname -s)" = Linux ]; then
    build_flags+=(--static-swift-stdlib)
fi
echo "==> swift build ${build_flags[*]} (in $source_dir)"
(cd "$source_dir" && swift build "${build_flags[@]}")

built="$(cd "$source_dir" && swift build "${build_flags[@]}" --show-bin-path)/$plugin"
install -m 0755 "$built" "$bin/$plugin"
rm -rf "$source_dir"
rmdir "$(dirname "$source_dir")" 2>/dev/null || true

installed="$("$bin/$plugin" --version)"
if [ "$installed" != "$plugin $version" ]; then
    echo "install-plugins: built '$installed', expected '$plugin $version'" >&2
    exit 1
fi
echo "install-plugins: $installed installed in $bin"
