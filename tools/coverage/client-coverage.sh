#!/usr/bin/env bash
# Client coverage: runs every package's `swift test --enable-code-coverage` and the app's
# `xcodebuild test -enableCodeCoverage YES`, exports lcov from each .profdata with
# `llvm-cov export -format=lcov`, merges them and writes client/build/coverage/sonar.xml in
# SonarQube's generic coverage format (docs/spec/testing.adoc, "Coverage and SonarQube").
#
#     tools/coverage/client-coverage.sh               # test everything, then export
#     tools/coverage/client-coverage.sh --export-only # reuse the artifacts of an earlier run
#     tools/coverage/client-coverage.sh --gate        # ... and fail below the client gate
#     tools/coverage/client-coverage.sh --gate-only   # gate an existing regions.json (CI)
#
# The client gate (docs/spec/decisions.adoc D-066) is 95% lines AND 95% llvm-cov *regions*:
# Swift's coverage mapping has no branch records, and regions (each if/guard/switch arm, ?:/??
# operand, loop body, closure) are the closest proxy.  tools/coverage/regions-gate.swift
# computes both over the same files Sonar measures (client sources, minus tests, generated
# code, dependency checkouts and build output) and exits 1 below either bar.
#
# Outputs, all under client/build/coverage/:
#     <Package>.lcov, WireTuner.lcov   per-binary lcov exports
#     client.lcov                      the merged tracefile
#     sonar.xml                        what sonar-scanner uploads; paths relative to client/,
#                                      the scanner's base dir (client/sonar-project.properties)
#     client.profdata                  every package's profile and the app's, merged
#     regions.json                     `llvm-cov export -summary-only` over client.profdata and
#                                      every instrumented binary: the region gate's input
#     WireTuner.xcresult               the app test result bundle
# The app build lives in client/build/DerivedData so the .profdata is at a known path.
set -euo pipefail

# Physical path: under /tmp (a symlink to /private/tmp) Xcode and SwiftPM would otherwise record
# the same sources under two spellings and the gate would count each file twice.
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
client="$root/client"
out="$client/build/coverage"
derived="$client/build/DerivedData"
project="$client/WireTuner.xcodeproj"
scheme="WireTuner"
export_only=false
gate=false
gate_only=false

for argument in "$@"; do
    case "$argument" in
        --export-only) export_only=true ;;
        --gate) gate=true ;;
        --gate-only) gate_only=true ;;
        *) echo "unknown argument: $argument" >&2; exit 2 ;;
    esac
done

# The files the gate measures: what sonar-project.properties lists as sources, nothing else.
# Substrings of absolute paths; --relative-to drops everything outside client/.
run_gate() {
    swift "$root/tools/coverage/regions-gate.swift" "$out/regions.json" \
        --relative-to "$client" \
        --exclude /.build/ --exclude /client/build/ \
        --exclude /Tests/ --exclude /WTAppTests/ --exclude /WTAppUITests/ \
        --exclude /Generated/ \
        --minimum 95 --minimum-lines 95
}

if [ "$gate_only" = true ]; then
    test -s "$out/regions.json" || { echo "no $out/regions.json; run without --gate-only first" >&2; exit 2; }
    run_gate
    exit $?
fi

mkdir -p "$out"
rm -f "$out"/*.lcov "$out/sonar.xml" "$out/regions.json" "$out/client.profdata"

# Every (profile, binary) pair that exported, for the merged region export below.
profiles=()
binaries=()

# --- Packages -------------------------------------------------------------------------------
for package in "$client"/Packages/*/; do
    name="$(basename "$package")"
    if [ "$export_only" = false ]; then
        echo "==> swift test --enable-code-coverage ($name)"
        (cd "$package" && swift test --enable-code-coverage)
    fi
    profdata="$package/.build/debug/codecov/default.profdata"
    binary="$package/.build/debug/${name}PackageTests.xctest/Contents/MacOS/${name}PackageTests"
    # A package whose artifacts are missing (not built yet, or its tests were not run with
    # coverage) is reported and skipped rather than aborting every other package's report.
    # The gate still sees its sources as uncovered through the app binary, which links them.
    if [ ! -f "$profdata" ] || [ ! -x "$binary" ]; then
        echo "warning: skipping $name: missing coverage artifacts ($profdata, $binary)" >&2
        continue
    fi
    if ! xcrun llvm-cov export -format=lcov -instr-profile "$profdata" "$binary" > "$out/$name.lcov"; then
        echo "warning: skipping $name: llvm-cov export failed" >&2
        rm -f "$out/$name.lcov"
        continue
    fi
    profiles+=("$profdata")
    binaries+=("$binary")
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
profiles+=("$profdata")
binaries+=("${objects[@]}")

# --- Merge and convert ----------------------------------------------------------------------
cat "$out"/*.lcov > "$out/client.lcov"
swift "$root/tools/coverage/lcov-to-sonar.swift" "$out/client.lcov" "$out/sonar.xml" \
    --relative-to "$client" --exclude /.build/ --exclude /client/build/
echo "coverage report: $out/sonar.xml"

# --- Regions --------------------------------------------------------------------------------
# One profile and one export over every binary, so a source compiled into several test
# binaries appears once with the union of their counts (the per-binary lcov files are merged
# line by line by lcov-to-sonar instead; regions cannot be merged that way because their
# boundaries are not in the lcov).  Functions whose hash differs between two builds of the same
# source are reported by llvm-cov as mismatched and counted from one of them.
xcrun llvm-profdata merge -sparse -o "$out/client.profdata" "${profiles[@]}"
args=()
for object in "${binaries[@]:1}"; do
    args+=(-object "$object")
done
xcrun llvm-cov export -format=text -summary-only -instr-profile "$out/client.profdata" \
    "${binaries[0]}" "${args[@]}" > "$out/regions.json" 2> "$out/regions-export.log" || {
    cat "$out/regions-export.log" >&2
    exit 1
}
echo "region export: $out/regions.json"

if [ "$gate" = true ]; then
    run_gate
fi
