#!/usr/bin/env bash
# Launch smoke test: starts the built WireTuner.app the way the Finder would -- its own process,
# its real main() -- and checks that it puts a document window on screen, then quits it.  A unit
# test cannot catch a broken launch (the test bundle is hosted in the app and main() skips the
# delegate for it), and a UI test needs Automation Mode; this needs neither, nor Accessibility or
# Screen Recording: CGWindowListCopyWindowInfo gives any process the owner, layer and bounds of
# on-screen windows.  It would have caught the launch that ran with a nil NSApplication delegate
# and no windows.
#
# The app is sandboxed, so HOME cannot redirect its container; the launch passes -WTUITesting
# instead, which keeps it off the real library, keychain and last session (memory documents, no
# sync, no session restore -- LaunchEnvironment) while still running main() and the delegate, and
# -ApplePersistenceIgnoreState so AppKit restores no windows of its own.  The environment is
# emptied (env -i) so nothing from the calling shell or an Xcode test run leaks in.
#
# Usage: tools/launch-smoke/launch-smoke.sh [path/to/WireTuner.app] [timeout seconds]
# Default app: client/build/DerivedData/Build/Products/Debug/WireTuner.app (make client-test's).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
app="${1:-$root/client/build/DerivedData/Build/Products/Debug/WireTuner.app}"
timeout="${2:-30}"
binary="$app/Contents/MacOS/WireTuner"
[[ -x "$binary" ]] || { echo "launch-smoke: no app at $app (build it first)" >&2; exit 2; }

work="$(mktemp -d)"
probe="$work/window-probe"
pid=""
cleanup() {
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

xcrun swiftc -O -o "$probe" "$here/window-probe.swift"

env -i HOME="$HOME" USER="${USER:-$(id -un)}" PATH=/usr/bin:/bin TMPDIR="${TMPDIR:-/tmp}" \
    "$binary" -WTUITesting -ApplePersistenceIgnoreState YES >"$work/app.log" 2>&1 &
pid=$!
disown "$pid"

deadline=$((SECONDS + timeout))
found=""
while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "launch-smoke: WireTuner exited during launch" >&2
        tail -20 "$work/app.log" >&2 || true
        pid=""
        exit 1
    fi
    windows="$("$probe" "$pid")"
    if [[ "${windows%% *}" -gt 0 ]]; then found="$windows"; break; fi
    sleep 0.5
done

if [[ -z "$found" ]]; then
    echo "launch-smoke: no document window on screen within ${timeout}s (pid $pid)" >&2
    tail -20 "$work/app.log" >&2 || true
    exit 1
fi
echo "launch-smoke: ok -- WireTuner (pid $pid) shows ${found%% *} document window(s): ${found#* }"
