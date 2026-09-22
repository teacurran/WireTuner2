#!/usr/bin/env bash
# Runs lcov-to-sonar.swift over the hand-written fixture and diffs the result against
# expected.xml.  The fixture exercises: line records, BRDA branch records with taken ("1"),
# not-taken ("-" and "0") branches, a second record for the same file that must merge (line 3
# stays covered, line 6 becomes covered, branch 5/0/0 becomes taken), XML escaping in a path,
# and a toolchain path outside --relative-to that must be dropped.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
converter="$here/../lcov-to-sonar.swift"
out="$(mktemp -d)/sonar.xml"

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

# Malformed input fails loudly.
if swift "$converter" <(printf 'DA:1,1\n') "$out" 2>/dev/null; then
    echo "expected a DA record before SF to be rejected" >&2
    exit 1
fi

echo "lcov-to-sonar: fixture test passed"
