#!/usr/bin/env bash
# `make release`: a beta of WireTuner as a DMG and a zip (docs/spec/releasing.adoc; D-080).
#
#   1. the Help Book, then an xcodebuild archive of the Release configuration (universal);
#   2. Developer ID: exportArchive (method developer-id) re-signs the app, its four extensions and
#      Sparkle's helpers, each with its own entitlements, hardened runtime and a secure timestamp;
#      no identity: the archived app as it is, ad-hoc signed -- an "unsigned test build";
#   3. a DMG (the app and an Applications link), signed; notarized with `notarytool submit --wait`
#      and stapled, the app inside stapled too;
#   4. a zip of the stapled app (Sparkle's enclosure), the dSYMs, SHA256SUMS and release.json;
#   5. tools/release/check.sh over the result (`make release-check`), then the appcast
#      (tools/release/appcast.sh), which signs it when the Sparkle key is present.
#
# The release is named YYYY.MM.DD-NNN (today, and the next number free among the git and GitHub
# tags; WT_RELEASE_NAME overrides), which is also the GitHub tag and title and the file stem:
# WireTuner-<name>.dmg / .zip and SHA256SUMS.txt.  Everything lands in client/build/release/<name>/
# (dist/ holds what ships), and client/build/release/release-dir.txt points the other make targets
# at it.  The app itself carries Version.xcconfig's version and build number.
# Credentials: see common.sh.  None present -> the unsigned test build, said loudly: ad-hoc signed,
# without the hardened runtime (library validation would refuse the embedded Sparkle.framework,
# whose ad-hoc signature has no team), publishable only as a GitHub pre-release.
source "$(dirname "$0")/common.sh"

version="$(release_marketing_version)"
build="$(release_build_number)"
[ -n "$version" ] && [ -n "$build" ] || die "no version in $release_version_file"
name="${WT_RELEASE_NAME:-$(next_release_name)}"
[[ "$name" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{3}$ ]] || die "release name '$name' is not YYYY.MM.DD-NNN"
if release_name_taken "$name"; then die "release $name already exists (a tag here or on $release_repo)"; fi
dir="$release_build_root/$name"
logs="$dir/logs"
dist="$dir/dist"

detect_signing
detect_notary
require_notarized="${WT_RELEASE_REQUIRE_NOTARIZED:-}"
if [ "$signing_mode" = unsigned ]; then
    [ "$require_notarized" != 1 ] || die "WT_RELEASE_REQUIRE_NOTARIZED=1 but no Developer ID Application identity (set WT_DEVELOPER_ID_IDENTITY or import the certificate)"
    loud "UNSIGNED TEST BUILD" \
        "No Developer ID Application identity was found (WT_DEVELOPER_ID_IDENTITY or the keychain)," \
        "so this build is ad-hoc signed and will not be notarized.  It runs on this Mac; Gatekeeper" \
        "blocks it anywhere it is downloaded.  Do not publish it.  Setup: docs/spec/releasing.adoc."
    notary_args=()
elif [ ${#notary_args[@]} -eq 0 ]; then
    [ "$require_notarized" != 1 ] || die "WT_RELEASE_REQUIRE_NOTARIZED=1 but no notarization credential (WT_NOTARY_PROFILE or WT_NOTARY_KEY_*)"
    loud "SIGNED BUT NOT NOTARIZED" \
        "Signing as: $signing_identity" \
        "No notarization credential (WT_NOTARY_PROFILE or WT_NOTARY_KEY_PATH/_ID/_ISSUER), so" \
        "Gatekeeper will refuse this build on other Macs.  Do not publish it."
fi
base="WireTuner-$name"

say "WireTuner $name: version $version ($build), $signing_mode${signing_team:+, team $signing_team}, into $dir"
rm -rf "$dir"
mkdir -p "$logs" "$dist"
printf '%s\n' "$dir" >"$release_pointer"

# `run_logged NAME CMD...`: runs with output in logs/NAME.log, the tail printed on failure.
run_logged() {
    local name="$1"
    shift
    if ! "$@" >"$logs/$name.log" 2>&1; then
        tail -n 40 "$logs/$name.log" >&2
        die "$name failed (full log: $logs/$name.log)"
    fi
}

# --- 1. build ------------------------------------------------------------------------------------
if command -v asciidoctor >/dev/null; then
    say "Help Book"
    run_logged help-book "$release_root/tools/help/help-book.sh"
else
    warn "asciidoctor not found: the app ships without the Help Book (the Help panel falls back to its catalog pages)"
fi

project=(-project "$release_client/WireTuner.xcodeproj" -scheme WireTuner -derivedDataPath "$release_derived")
say "resolving packages"
run_logged resolve xcodebuild -resolvePackageDependencies "${project[@]}"

public_key="$(sparkle_public_key)"
if [ -z "$public_key" ]; then
    if [ "$require_notarized" = 1 ]; then die "no Sparkle public key (WT_SPARKLE_PUBLIC_KEY or generate_keys in this keychain): the build could never update"; fi
    warn "no Sparkle public key (WT_SPARKLE_PUBLIC_KEY or the keychain): this build's updater stays off"
fi

settings=(
    CODE_SIGN_IDENTITY="$signing_identity"
    DEVELOPMENT_TEAM="$signing_team"
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    WT_SPARKLE_PUBLIC_KEY="$public_key"
    # Strip our own products (app 664 MB -> 306 MB).  Not COPY_PHASE_STRIP: it strips the already
    # signed Sparkle binaries as they are copied and breaks their signatures.
    DEPLOYMENT_POSTPROCESSING=YES
    STRIP_INSTALLED_PRODUCT=YES
    STRIP_STYLE=non-global
)
if [ "$signing_mode" = developer-id ]; then
    settings+=(OTHER_CODE_SIGN_FLAGS=--timestamp)
else
    # Ad-hoc code has no team, so library validation under the hardened runtime refuses Sparkle
    # ("different Team IDs") and the app aborts at launch.  Developer ID builds keep it (one team;
    # notarization requires it).
    settings+=(ENABLE_HARDENED_RUNTIME=NO)
fi
if [ -n "${WT_RELEASE_ARCHS:-}" ]; then settings+=(ARCHS="$WT_RELEASE_ARCHS" ONLY_ACTIVE_ARCH=NO); fi
# The production endpoints, when the release names them; otherwise the compose defaults stay.
for endpoint in WT_AUTH_ISSUER WT_API_URL WT_LINKS_URL; do
    if [ -n "${!endpoint:-}" ]; then settings+=("$endpoint=${!endpoint}"); fi
done
[ -n "${WT_API_URL:-}" ] || warn "WT_API_URL is not set: the build talks to the compose stack's http://localhost:8080"

archive="$dir/WireTuner.xcarchive"
say "archiving (Release) -> $archive"
run_logged archive xcodebuild archive "${project[@]}" -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$archive" "${settings[@]}"

# --- 2. export -----------------------------------------------------------------------------------
export_dir="$dir/export"
app="$export_dir/WireTuner.app"
if [ "$signing_mode" = developer-id ]; then
    say "exporting (developer-id)"
    options="$dir/ExportOptions.plist" # Holds the team id: generated here, never committed.
    cat >"$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$signing_team</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>$signing_identity</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
    run_logged export xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" -exportOptionsPlist "$options"
else
    mkdir -p "$export_dir"
    ditto "$archive/Products/Applications/WireTuner.app" "$app"
fi
[ -d "$app" ] || die "no app at $app"
built_version="$(plist_value "$app/Contents/Info.plist" CFBundleShortVersionString)"
built_build="$(plist_value "$app/Contents/Info.plist" CFBundleVersion)"
[ "$built_version ($built_build)" = "$version ($build)" ] || die "the app says $built_version ($built_build), Version.xcconfig $version ($build)"
run_logged codesign-verify codesign --verify --deep --strict --verbose=2 "$app"

# --- 3. DMG, notarization, stapling --------------------------------------------------------------
dmg="$dist/$base.dmg"
say "DMG -> $dmg"
staging="$dir/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/WireTuner.app"
ln -s /Applications "$staging/Applications"
run_logged dmg hdiutil create -volname "WireTuner $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
rm -rf "$staging"
if [ "$signing_mode" = developer-id ]; then
    run_logged dmg-sign codesign --sign "$signing_identity" --timestamp "$dmg"
fi

notarized=false
if [ ${#notary_args[@]} -gt 0 ]; then
    say "notarizing (notarytool submit --wait; usually a few minutes)"
    if ! xcrun notarytool submit "$dmg" "${notary_args[@]}" --wait --timeout 2h --output-format json >"$logs/notarize.json" 2>"$logs/notarize.err"; then
        cat "$logs/notarize.err" >&2
    fi
    status="$(plutil -extract status raw -o - "$logs/notarize.json" 2>/dev/null || true)"
    submission="$(plutil -extract id raw -o - "$logs/notarize.json" 2>/dev/null || true)"
    if [ -n "$submission" ]; then
        xcrun notarytool log "$submission" "${notary_args[@]}" "$logs/notarize-log.json" >/dev/null 2>&1 || true
    fi
    [ "$status" = Accepted ] || die "notarization ${status:-failed} (submission ${submission:-none}; see $logs/notarize-log.json and notarize.err)"
    run_logged staple-dmg xcrun stapler staple "$dmg"
    run_logged staple-app xcrun stapler staple "$app"
    run_logged staple-validate xcrun stapler validate "$app"
    notarized=true
fi

# --- 4. zip, symbols, checksums, manifest --------------------------------------------------------
zip="$dist/$base.zip"
say "zip -> $zip"
(cd "$export_dir" && ditto -c -k --sequesterRsrc --keepParent WireTuner.app "$zip")
if [ -d "$archive/dSYMs" ] && [ -n "$(ls "$archive/dSYMs")" ]; then
    (cd "$archive" && ditto -c -k --keepParent dSYMs "$dir/$base-dSYMs.zip")
fi
(cd "$dist" && shasum -a 256 "$base.dmg" "$base.zip" >SHA256SUMS.txt)

feed="$(plist_value "$app/Contents/Info.plist" SUFeedURL)"
cat >"$dir/release.json" <<JSON
{
  "name": "$name",
  "repo": "$release_repo",
  "version": "$version",
  "build": $build,
  "commit": "$(release_commit)",
  "signing": "$signing_mode",
  "team": "$signing_team",
  "notarized": $notarized,
  "feed": "$feed",
  "sparklePublicKey": "$public_key",
  "dmg": "$base.dmg",
  "zip": "$base.zip",
  "built": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

# --- 5. check, appcast ---------------------------------------------------------------------------
"$release_root/tools/release/check.sh" "$app" "$dmg"
"$release_root/tools/release/appcast.sh"

say "done: $dist"
(cd "$dist" && ls -l)
if [ "$notarized" != true ]; then
    loud "TEST BUILD: $base (signing: $signing_mode, notarized: $notarized)" \
        "make release-publish offers it only as a GitHub pre-release; make release-upload refuses it."
fi
