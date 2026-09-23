#!/usr/bin/env bash
# Tests for the coverage tools, fixture-driven so they run without Xcode's test artifacts.
#
# lcov-to-sonar.swift over fixture.lcov, diffed against expected.xml.  The fixture exercises:
# line records, BRDA branch records with taken ("1"), not-taken ("-" and "0") branches, a second
# record for the same file that must merge (line 3 stays covered, line 6 becomes covered, branch
# 5/0/0 becomes taken), a wrapped-negative llvm counter (DA:8,18446744073709551588, read as 0
# hits), XML escaping in a path, and a toolchain path outside --relative-to that must be dropped.
#
# jacoco-gate.sh over jacoco-a.xml and jacoco-b.xml: see its section below.
#
# regions-gate.swift over regions-fixture.json: six files of which only Bezier.swift (90/100
# regions, 96/100 lines) and AppDelegate.swift (10/10, 20/20) survive the filters; the test file,
# the generated protobuf, the dependency checkout and the toolchain source are dropped.  Kept
# total: regions 100/110 = 90.91%, lines 116/120 = 96.67%.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
converter="$here/../lcov-to-sonar.swift"
gate="$here/../regions-gate.swift"
work="$(mktemp -d)"
out="$work/sonar.xml"

# --- lcov-to-sonar ------------------------------------------------------------------------------
swift "$converter" "$here/fixture.lcov" "$out" --relative-to /repo
diff -u "$here/expected.xml" "$out"

# Without --relative-to every path is kept verbatim.
swift "$converter" "$here/fixture.lcov" "$out"
grep -q 'path="/Applications/Xcode.app/Contents/Developer/Toolchains/runner.swift"' "$out"
grep -q 'path="/repo/client/WTApp/Menu&amp;Items.swift"' "$out"

# --exclude drops files by path substring (dependency checkouts in the real run).
swift "$converter" "$here/fixture.lcov" "$out" --relative-to /repo --exclude /WTApp/
grep -q 'Bezier.swift' "$out"
if grep -q 'Menu&amp;Items.swift' "$out"; then
    echo "expected --exclude /WTApp/ to drop the WTApp file" >&2
    exit 1
fi

# Malformed input fails loudly: a DA record before any SF, and a hit count that is not a number.
if swift "$converter" <(printf 'DA:1,1\n') "$out" 2>/dev/null; then
    echo "expected a DA record before SF to be rejected" >&2
    exit 1
fi
if swift "$converter" <(printf 'SF:/repo/a.swift\nDA:1,-3\nend_of_record\n') "$out" 2>/dev/null; then
    echo "expected a negative hit count to be rejected" >&2
    exit 1
fi

echo "lcov-to-sonar: fixture test passed"

# --- regions-gate -------------------------------------------------------------------------------
filters=(--relative-to /repo --exclude /.build/ --exclude /Tests/ --exclude /Generated/)
summary="$work/summary.md"

# Below the default 95% gate: exit 1, figures printed, summary appended to the --summary file.
set +e
swift "$gate" "$here/regions-fixture.json" "${filters[@]}" --summary "$summary" > "$work/gate.out"
status=$?
set -e
test "$status" -eq 1 || { echo "expected exit 1 below the gate, got $status" >&2; cat "$work/gate.out"; exit 1; }
grep -q '^| Lines | 116 | 120 | 96.67% |$' "$work/gate.out"
grep -q '^| Regions (branch gate, D-066) | 100 | 110 | 90.91% |$' "$work/gate.out"
grep -q 'FAIL: region coverage 90.91% is below the 95.00% gate' "$work/gate.out"
grep -q 'Bezier.swift | 90 | 100 | 90.00%' "$work/gate.out"
grep -q '(llvm-cov, 2 files)' "$work/gate.out"
grep -q 'Regions (branch gate, D-066) | 100 | 110' "$summary"
if grep -q 'BezierTests\|Generated\|checkouts\|Toolchains' "$work/gate.out"; then
    echo "expected tests, generated code, checkouts and toolchain sources to be filtered out" >&2
    exit 1
fi

# A lower bar passes; the --summary file is appended to, not replaced.
swift "$gate" "$here/regions-fixture.json" "${filters[@]}" --minimum 90 --summary "$summary" > "$work/gate.out"
grep -q 'PASS: region coverage 90.91% meets the 90.00% gate' "$work/gate.out"
test "$(grep -c 'Client coverage' "$summary")" -eq 2

# --minimum-lines gates lines too.
if swift "$gate" "$here/regions-fixture.json" "${filters[@]}" --minimum 90 --minimum-lines 97 --summary /dev/null > "$work/gate.out"; then
    echo "expected --minimum-lines 97 to fail at 96.67%" >&2
    exit 1
fi
grep -q 'FAIL: line coverage 96.67% is below the 97.00% gate' "$work/gate.out"

# Several exports (one per owning test binary) are totalled file list by file list.
swift "$gate" "$here/regions-fixture.json" "$here/regions-fixture.json" "${filters[@]}" --minimum 90 --summary /dev/null > "$work/gate.out"
grep -q '^| Regions (branch gate, D-066) | 200 | 220 | 90.91% |$' "$work/gate.out"
grep -q '(llvm-cov, 4 files)' "$work/gate.out"

# Everything filtered out is a failure, not a vacuous pass.
if swift "$gate" "$here/regions-fixture.json" --relative-to /nowhere --summary /dev/null > "$work/gate.out"; then
    echo "expected an empty file set to fail" >&2
    exit 1
fi
grep -q 'FAIL: no measurable regions' "$work/gate.out"

# Usage and input errors exit 2.
set +e
swift "$gate" "$work/missing.json" --summary /dev/null >/dev/null 2>&1; test $? -eq 2 || { echo "expected exit 2 for a missing file" >&2; exit 1; }
swift "$gate" <(printf '{"type":"other"}') --summary /dev/null >/dev/null 2>&1; test $? -eq 2 || { echo "expected exit 2 for a non-llvm-cov file" >&2; exit 1; }
swift "$gate" "$here/regions-fixture.json" --minimum 120 --summary /dev/null >/dev/null 2>&1; test $? -eq 2 || { echo "expected exit 2 for an invalid percentage" >&2; exit 1; }
set -e

echo "regions-gate: fixture test passed"

# --- jacoco-gate ---------------------------------------------------------------------------------
# jacoco-a.xml (one line, as JaCoCo writes it): report totals LINE 57/60, BRANCH 18/20; the
# package/class/sourcefile counters before the last </package> must be ignored.  jacoco-b.xml
# (pretty-printed, no BRANCH counter): LINE 39/40.  Sum: lines 96/100, branches 18/20 = 90%.
jacoco_gate="$here/../jacoco-gate.sh"
set +e
"$jacoco_gate" --summary "$work/jacoco.md" "$here/jacoco-a.xml" "$here/jacoco-b.xml" > "$work/jacoco.out"
status=$?
set -e
test "$status" -eq 1 || { echo "expected jacoco-gate to fail at 90% branches, got $status" >&2; cat "$work/jacoco.out"; exit 1; }
grep -q 'Total\*\* | \*\*96/100 (96.00%)\*\* | \*\*18/20 (90.00%)\*\*' "$work/jacoco.out"
grep -q 'PASS: line coverage 96.00% meets the 95% gate' "$work/jacoco.out"
grep -q 'FAIL: branch coverage 90.00% is below the 95% gate' "$work/jacoco.out"
grep -q '18/20 (90.00%)' "$work/jacoco.md"
"$jacoco_gate" --minimum 90 --summary /dev/null "$here/jacoco-a.xml" "$here/jacoco-b.xml" | grep -q 'PASS: branch coverage 90.00% meets the 90% gate'
"$jacoco_gate" --summary /dev/null "$here/jacoco-b.xml" | grep -q 'PASS: no branches to cover'
set +e
"$jacoco_gate" --summary /dev/null "$work/missing.xml" >/dev/null 2>&1; test $? -eq 2 || { echo "expected exit 2 for a missing report" >&2; exit 1; }
"$jacoco_gate" --summary /dev/null >/dev/null 2>&1; test $? -eq 2 || { echo "expected exit 2 without reports" >&2; exit 1; }
set -e

echo "jacoco-gate: fixture test passed"
