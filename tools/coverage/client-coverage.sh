#!/usr/bin/env bash
# Client coverage: runs every package's `swift test --enable-code-coverage` and the app's
# `xcodebuild test -enableCodeCoverage YES`, exports lcov from each .profdata with
# `llvm-cov export -format=lcov`, merges them and writes client/build/coverage/sonar.xml in
# SonarQube's generic coverage format (docs/spec/testing.adoc, "Coverage and SonarQube").
#
#     tools/coverage/client-coverage.sh              # test everything, then export
#     tools/coverage/client-coverage.sh --export-only # reuse the artifacts of an earlier run
#
# Outputs, all under client/build/coverage/:
#     <Package>.lcov, WireTuner.lcov   per-binary lcov exports
#     client.lcov                      the merged tracefile
#     sonar.xml                        what sonar-scanner uploads (TEST-003)
#     WireTuner.xcresult               the app test result bundle
# The app build lives in client/build/DerivedData so the .profdata is at a known path.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
client="$root/client"
out="$client/build/coverage"
derived="$client/build/DerivedData"
project="$client/WireTuner.xcodeproj"
scheme="WireTuner"
export_only=false

for argument in "$@"; do
    case "$argument" in
        --export-only) export_only=true ;;
        *) echo "unknown argument: $argument" >&2; exit 2 ;;
    esac
done

mkdir -p "$out"
rm -f "$out"/*.lcov "$out/sonar.xml"

# --- Packages -------------------------------------------------------------------------------
for package in "$client"/Packages/*/; do
    name="$(basename "$package")"
    if [ "$export_only" = false ]; then
        echo "==> swift test --enable-code-coverage ($name)"
        (cd "$package" && swift test --enable-code-coverage)
    fi
    profdata="$package/.build/debug/codecov/default.profdata"
    binary="$package/.build/debug/${name}PackageTests.xctest/Contents/MacOS/${name}PackageTests"
    if [ ! -f "$profdata" ] || [ ! -x "$binary" ]; then
        echo "missing coverage artifacts for $name ($profdata, $binary)" >&2
        exit 1
    fi
    xcrun llvm-cov export -format=lcov -instr-profile "$profdata" "$binary" > "$out/$name.lcov"
done

# --- App ------------------------------------------------------------------------------------
if [ "$export_only" = false ]; then
    # XCUITest driven from the command line needs macOS Automation Mode (GitHub's macOS runners
    # have it on).  On a developer Mac it is off until someone runs
    #     sudo automationmodetool enable-automationmode-without-authentication
    # so rather than fail with "Timed out while enabling automation mode", skip the UI target
    # and say so; the unit tests and the app build still run and still produce coverage.
    skip=()
    if ! automationmodetool status 2>/dev/null | grep -qi "is enabled"; then
        echo "warning: macOS Automation Mode is disabled; skipping WireTunerUITests" >&2
        echo "         (enable it once with: sudo automationmodetool enable-automationmode-without-authentication)" >&2
        skip=(-skip-testing:WireTunerUITests)
    fi
    echo "==> xcodebuild test ($scheme)"
    rm -rf "$out/WireTuner.xcresult"
    xcodebuild test \
        -project "$project" -scheme "$scheme" -destination 'platform=macOS' \
        -enableCodeCoverage YES \
        -derivedDataPath "$derived" \
        -resultBundlePath "$out/WireTuner.xcresult" \
        "${skip[@]}" \
        CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
        | tee "$out/xcodebuild-test.log" | grep -E '^(Test Suite|Test Case|\*\*|Executed|error:|warning:)' || true
    test "${PIPESTATUS[0]}" -eq 0
fi

# Xcode writes the merged profile into DerivedData; the xcresult keeps a copy under Data/.
profdata="$(find "$derived/Build/ProfileData" -name Coverage.profdata 2>/dev/null | head -1 || true)"
if [ -z "$profdata" ]; then
    profdata="$(find "$out/WireTuner.xcresult" -name '*.profdata' 2>/dev/null | head -1 || true)"
fi
if [ -z "$profdata" ]; then
    echo "no Coverage.profdata under $derived/Build/ProfileData or $out/WireTuner.xcresult" >&2
    exit 1
fi
# Which binaries carry coverage mapping depends on Xcode's layout: since Xcode 16 a Debug app's
# executable is a small stub and the code (with its __llvm_covmap) is in
# WireTuner.app/Contents/MacOS/WireTuner.debug.dylib; the hosted unit-test bundle sits in the
# app's PlugIns and the UI-test bundle in its runner app.  Rather than hard-code that, take
# every Mach-O under the products that has a __llvm_covmap section.
products="$derived/Build/Products/Debug"
objects=()
while IFS= read -r candidate; do
    if otool -l "$candidate" 2>/dev/null | grep -q '__llvm_covmap'; then
        objects+=("$candidate")
    fi
done < <(find "$products/WireTuner.app" "$products/WireTunerUITests-Runner.app" -type f -perm -u+x \
            \( -path '*/MacOS/*' -o -path '*/Frameworks/*.dylib' \) -not -path '*/Sparkle.framework/*' 2>/dev/null | sort)
if [ "${#objects[@]}" -eq 0 ]; then
    echo "no instrumented binaries under $products (was the app built with -enableCodeCoverage YES?)" >&2
    exit 1
fi
echo "==> llvm-cov export: ${objects[*]#"$products"/}"
args=()
for object in "${objects[@]:1}"; do
    args+=(-object "$object")
done
xcrun llvm-cov export -format=lcov -instr-profile "$profdata" "${objects[0]}" "${args[@]}" > "$out/WireTuner.lcov"

# --- Merge and convert ----------------------------------------------------------------------
cat "$out"/*.lcov > "$out/client.lcov"
swift "$root/tools/coverage/lcov-to-sonar.swift" "$out/client.lcov" "$out/sonar.xml" \
    --relative-to "$root" --exclude /.build/ --exclude client/build/
echo "coverage report: $out/sonar.xml"
