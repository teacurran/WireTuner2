#!/usr/bin/env bash
# `make release-check`: verifies an exported WireTuner.app (and its DMG) is fit to ship
# (docs/spec/releasing.adoc, "What release-check verifies").
#
#     tools/release/check.sh [APP [DMG]]    # default: this version's client/build/release/.../export
#
# Every Mach-O in the bundle: a valid strict signature, no get-task-allow; when Developer ID signed,
# the hardened runtime, the Developer ID authority, the one team and a secure timestamp; when ad-hoc,
# no hardened runtime on our code (library validation would refuse Sparkle and the app would abort).  The app and
# each extension: sandboxed, with its own entitlements (dumped to logs/entitlements/), the app
# group resolving to "<team>.com.villagecompute.wiretuner" in the app and the share extension and
# matching their WTAppGroup, and the app's version on every bundle.  Sparkle: an https feed and,
# when signed, a public key.  Gatekeeper (spctl) and the stapled ticket when signed; the DMG
# verified, mounted and its app checked.  Last, the app is launched (open -n) and must still be
# running 8 seconds later with no new crash report (WT_RELEASE_SKIP_LAUNCH=1 skips it).  An ad-hoc "unsigned test build" skips the checks only a
# Developer ID signature can pass, and says so.  Exit 1 on any failure.
source "$(dirname "$0")/common.sh"

# A subshell: release_dir exits when nothing is built yet, and APP may still be given.
dir="$( (release_dir) 2>/dev/null || true)"
app="${1:-$dir/export/WireTuner.app}"
dmg="${2:-}"
if [ -z "$dmg" ] && [ $# -lt 1 ]; then dmg="$(ls "$dir"/dist/*.dmg 2>/dev/null | head -n 1 || true)"; fi
[ -d "$app" ] || die "no app at $app (run make release, or pass APP=/path/to/WireTuner.app)"
app="$(cd "$app" && pwd)"
logs="$(dirname "$(dirname "$app")")/logs"
mkdir -p "$logs/entitlements"

passes=0 failures=0 warnings=0 skips=0
pass() { passes=$((passes + 1)); printf '  pass  %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }
warn_check() { warnings=$((warnings + 1)); printf '  warn  %s\n' "$*"; }
skip() { skips=$((skips + 1)); printf '  skip  %s\n' "$*"; }

rel() { local path="${1#"$app"}"; echo "WireTuner.app${path}"; }
details() { codesign -dvvv "$1" 2>&1 || true; }
# `entitlements CODE FILE`: the code's entitlements as an XML plist in FILE (empty when none).
entitlements() { codesign -d --entitlements - --xml "$1" >"$2" 2>/dev/null || : >"$2"; }
# `entitlement_value FILE KEY`: a boolean or string, or an array's first element, as text.
entitlement_value() {
    [ -s "$1" ] || return 0
    /usr/libexec/PlistBuddy -c "Print :$2:0" "$1" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}
scratch="$(mktemp -d "${TMPDIR:-/tmp}/release-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

app_details="$(details "$app")"
if printf '%s' "$app_details" | grep -q '^Signature=adhoc'; then
    mode=unsigned team=""
    echo "release-check: $(rel "$app"), ad-hoc signed (an unsigned test build: Developer ID checks skipped)"
else
    mode=developer-id
    team="$(printf '%s' "$app_details" | sed -n 's/^TeamIdentifier=//p')"
    echo "release-check: $(rel "$app"), Developer ID, team $team"
fi
info="$app/Contents/Info.plist"
version="$(plist_value "$info" CFBundleShortVersionString)"
build="$(plist_value "$info" CFBundleVersion)"
echo "  version $version ($build)"

echo "Signatures"
if codesign --verify --deep --strict --verbose=2 "$app" >"$logs/check-verify.log" 2>&1; then
    pass "codesign --verify --deep --strict"
else
    fail "codesign --verify --deep --strict (logs/check-verify.log)"
fi

# Every Mach-O file: the bundle executables, Sparkle's Autoupdate, any dylib.
machos=()
while IFS= read -r -d '' file; do
    if file -b "$file" | grep -q 'Mach-O'; then machos+=("$file"); fi
done < <(find "$app" -type f -perm +111 -print0)
for file in "${machos[@]}"; do
    name="$(rel "$file")"
    d="$(details "$file")"
    problems=()
    codesign --verify --strict "$file" >/dev/null 2>&1 || problems+=("signature invalid")
    if printf '%s' "$d" | grep -q '^CodeDirectory.*flags=.*runtime'; then hardened=true; else hardened=false; fi
    if [ "$mode" = developer-id ] && [ "$hardened" = false ]; then problems+=("no hardened runtime"); fi
    # Sparkle's own binaries arrive hardened and ad-hoc signed by Sparkle; only ours must not be.
    if [ "$mode" = unsigned ] && [ "$hardened" = true ] && [[ "$file" != */Sparkle.framework/* ]]; then
        problems+=("hardened runtime on ad-hoc code (library validation refuses Sparkle: the app aborts at launch)")
    fi
    entitlements "$file" "$scratch/entitlements.plist"
    if [ "$(entitlement_value "$scratch/entitlements.plist" com.apple.security.get-task-allow)" = true ]; then
        problems+=("get-task-allow (notarization refuses it)")
    fi
    if [ "$mode" = developer-id ]; then
        printf '%s' "$d" | grep -q '^Authority=Developer ID Application:' || problems+=("not Developer ID signed")
        [ "$(printf '%s' "$d" | sed -n 's/^TeamIdentifier=//p')" = "$team" ] || problems+=("team is not $team")
        printf '%s' "$d" | grep -q '^Timestamp=' || problems+=("no secure timestamp")
    fi
    if [ ${#problems[@]} -eq 0 ]; then
        pass "$name"
    else
        fail "$name: $(IFS=';'; echo "${problems[*]}")"
    fi
done
[ ${#machos[@]} -gt 5 ] || fail "only ${#machos[@]} Mach-O files: the extensions or Sparkle are missing"

echo "Entitlements and bundles (dumps in logs/entitlements/)"
group_expected="${team:+$team.}com.villagecompute.wiretuner"
bundles=("$app")
while IFS= read -r -d '' appex; do bundles+=("$appex"); done < <(find "$app/Contents/PlugIns" -maxdepth 1 -name '*.appex' -print0 2>/dev/null)
[ ${#bundles[@]} -eq 5 ] || fail "expected the app and 4 extensions, found ${#bundles[@]} bundles"
for bundle in "${bundles[@]}"; do
    name="$(basename "$bundle")"
    xml="$logs/entitlements/$name.plist"
    entitlements "$bundle" "$xml"
    bundle_info="$bundle/Contents/Info.plist"
    [ "$(entitlement_value "$xml" com.apple.security.app-sandbox)" = true ] && pass "$name: sandboxed" || fail "$name: not sandboxed"
    bundle_version="$(plist_value "$bundle_info" CFBundleShortVersionString) ($(plist_value "$bundle_info" CFBundleVersion))"
    [ "$bundle_version" = "$version ($build)" ] && pass "$name: $bundle_version" || fail "$name: version $bundle_version, app $version ($build)"
    group="$(entitlement_value "$xml" com.apple.security.application-groups)"
    declared="$(plist_value "$bundle_info" WTAppGroup)"
    if [ -n "$group$declared" ]; then
        if [ "$group" = "$group_expected" ] && [ "$declared" = "$group" ]; then
            pass "$name: app group $group"
        else
            fail "$name: app group entitlement '$group', WTAppGroup '$declared', expected '$group_expected'"
        fi
    elif [ "$name" = WireTuner.app ] || [ "$name" = WireTunerShare.appex ]; then
        fail "$name: no app group (the share extension's inbox needs one)"
    fi
done

echo "Sparkle"
feed="$(plist_value "$info" SUFeedURL)"
case "$feed" in https://*/appcast.xml) pass "SUFeedURL $feed" ;; *) fail "SUFeedURL '$feed' is not an https appcast" ;; esac
key="$(plist_value "$info" SUPublicEDKey)"
if [ -n "$key" ]; then
    printf '%s' "$key" | base64 -d 2>/dev/null | wc -c | grep -q '^ *32$' && pass "SUPublicEDKey is a 32-byte EdDSA key" || fail "SUPublicEDKey '$key' is not a base64 32-byte key"
elif [ "$mode" = developer-id ]; then
    fail "no SUPublicEDKey: this build could never update (WT_SPARKLE_PUBLIC_KEY or generate_keys)"
else
    warn_check "no SUPublicEDKey: the updater stays off in this build"
fi
[ -d "$app/Contents/Frameworks/Sparkle.framework" ] && pass "Sparkle.framework embedded" || fail "Sparkle.framework missing"

# The shared packages are linked once, into WireTunerKit.framework in the app's Frameworks, which the
# app and the Spotlight importer load (D-084): no second copy, and the importer finds the app's.
echo "Shared framework"
kit="$app/Contents/Frameworks/WireTunerKit.framework"
[ -d "$kit" ] && pass "WireTunerKit.framework embedded" || fail "WireTunerKit.framework missing"
copies="$(find "$app" -name 'WireTunerKit.framework' -type d | wc -l | tr -d ' ')"
[ "$copies" = 1 ] && pass "one WireTunerKit.framework in the bundle" || fail "$copies copies of WireTunerKit.framework (only the app embeds it)"
importer="$app/Contents/PlugIns/WireTunerSpotlightImporter.appex/Contents/MacOS/WireTunerSpotlightImporter"
for code in "$app/Contents/MacOS/WireTuner" "$importer"; do
    if otool -L "$code" 2>/dev/null | grep -q '@rpath/WireTunerKit.framework/'; then
        pass "$(basename "$code") loads WireTunerKit.framework"
    else
        fail "$(basename "$code") does not load WireTunerKit.framework (the packages linked statically again?)"
    fi
done
if otool -l "$importer" 2>/dev/null | grep -q 'path @executable_path/../../../../Frameworks '; then
    pass "the Spotlight importer's runpath reaches the app's Frameworks"
else
    fail "the Spotlight importer has no @executable_path/../../../../Frameworks runpath"
fi

echo "Gatekeeper"
assessment="$(spctl -a -vvv -t exec "$app" 2>&1 || true)"
printf '%s\n' "$assessment" >"$logs/check-spctl.log"
if [ "$mode" = developer-id ]; then
    if printf '%s' "$assessment" | grep -q ': accepted'; then
        pass "spctl: $(printf '%s' "$assessment" | sed -n 's/^source=//p')"
    else
        fail "spctl rejects the app: $(printf '%s' "$assessment" | tr '\n' ' ')"
    fi
    if xcrun stapler validate "$app" >/dev/null 2>&1; then pass "notarization ticket stapled to the app"; else warn_check "no stapled ticket on the app (not notarized?)"; fi
else
    skip "spctl (ad-hoc): $(printf '%s' "$assessment" | head -n 1)"
fi

if [ -n "$dmg" ]; then
    echo "DMG $(basename "$dmg")"
    if hdiutil verify "$dmg" >"$logs/check-dmg-verify.log" 2>&1; then pass "hdiutil verify"; else fail "hdiutil verify (logs/check-dmg-verify.log)"; fi
    if [ "$mode" = developer-id ]; then
        codesign --verify --strict "$dmg" >/dev/null 2>&1 && pass "DMG signature" || fail "DMG is not signed"
        dmg_assessment="$(spctl -a -t open --context context:primary-signature -vvv "$dmg" 2>&1 || true)"
        printf '%s' "$dmg_assessment" | grep -q ': accepted' && pass "spctl (DMG): $(printf '%s' "$dmg_assessment" | sed -n 's/^source=//p')" \
            || fail "spctl rejects the DMG: $(printf '%s' "$dmg_assessment" | tr '\n' ' ')"
        if xcrun stapler validate "$dmg" >/dev/null 2>&1; then pass "notarization ticket stapled to the DMG"; else warn_check "no stapled ticket on the DMG"; fi
    else
        skip "DMG signature and spctl (ad-hoc)"
    fi
    mount="$(mktemp -d "${TMPDIR:-/tmp}/wiretuner-dmg.XXXXXX")"
    if hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mount" "$dmg" >/dev/null 2>&1; then
        inner="$mount/WireTuner.app"
        if [ -d "$inner" ] && codesign --verify --deep --strict "$inner" >/dev/null 2>&1 \
            && [ "$(plist_value "$inner/Contents/Info.plist" CFBundleVersion)" = "$build" ]; then
            pass "the DMG's WireTuner.app verifies and is build $build"
        else
            fail "the DMG's WireTuner.app is missing, invalid or another build"
        fi
        [ -L "$mount/Applications" ] && pass "the DMG has an Applications link" || warn_check "the DMG has no Applications link"
        hdiutil detach "$mount" -quiet || hdiutil detach "$mount" -force -quiet || true
    else
        fail "the DMG does not mount"
    fi
    rmdir "$mount" 2>/dev/null || true
fi

echo "Launch"
if [ "${WT_RELEASE_SKIP_LAUNCH:-}" = 1 ]; then
    skip "launch test (WT_RELEASE_SKIP_LAUNCH=1)"
else
    reports="$HOME/Library/Logs/DiagnosticReports"
    marker="$scratch/launch-marker"
    touch "$marker"
    executable="$app/Contents/MacOS/WireTuner"
    open -n "$app" --args -ApplePersistenceIgnoreState YES
    pid=""
    for _ in $(seq 20); do
        pid="$(pgrep -f "^$executable" | head -n 1 || true)"
        [ -n "$pid" ] && break
        sleep 0.5
    done
    if [ -z "$pid" ]; then
        fail "the app did not start"
    else
        sleep 8
        if kill -0 "$pid" 2>/dev/null; then
            pass "the app launched and is still running after 8 s (pid $pid)"
            kill -TERM "$pid" 2>/dev/null || true
            for _ in $(seq 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
            kill -KILL "$pid" 2>/dev/null || true
        else
            fail "the app exited within 8 s of launch"
        fi
    fi
    crashes="$(find "$reports" -maxdepth 1 -name 'WireTuner*' -newer "$marker" 2>/dev/null || true)"
    if [ -n "$crashes" ]; then
        fail "crash report(s): $(printf '%s' "$crashes" | tr '\n' ' ')"
        head -n 40 "$(printf '%s\n' "$crashes" | head -n 1)" >"$logs/check-crash.txt" 2>/dev/null || true
    else
        pass "no new WireTuner crash report in $reports"
    fi
fi

echo "release-check: $passes passed, $failures failed, $warnings warnings, $skips skipped ($mode)"
[ "$failures" -eq 0 ]
