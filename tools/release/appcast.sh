#!/usr/bin/env bash
# `make appcast`: this release's appcast.xml, from the published one plus this build
# (docs/spec/releasing.adoc, "The appcast").  `make release` runs it last.
#
#   - The base is the channel's published appcast (the app's SUFeedURL; WT_APPCAST_BASE names a
#     file or URL instead).  Not there yet (404) -> a new appcast.  The build number must be newer
#     than every item in it.
#   - The enclosure is the zip: its GitHub release asset,
#     https://github.com/<repo>/releases/download/<name>/WireTuner-<name>.zip (D-080), or with
#     WT_APPCAST_ENCLOSURE=r2 the copy beside the appcast on R2.  It is signed with the Sparkle EdDSA key via sign_update: the key in the
#     keychain (generate_keys), or WT_SPARKLE_KEY_FILE.  The signature is checked against the app's
#     SUPublicEDKey before anything is written, so a wrong key cannot strand installed copies.
#   - Release notes: WT_RELEASE_NOTES, else docs/release-notes/<version>-<build>.md, else
#     docs/release-notes/<version>.md (Markdown).
#   - The finished feed is signed too (sign_update on the XML embeds the signature).
#
# Without a key, or for a test build, the appcast is written unsigned and marked so; the upload
# refuses it.  Output: <release>/dist/appcast.xml.
source "$(dirname "$0")/common.sh"

dir="$(release_dir)"
manifest="$dir/release.json"
[ -f "$manifest" ] || die "no $manifest: run make release first"
field() { plutil -extract "$1" raw -o - "$manifest"; }
name="$(field name)" repo="$(field repo)"
version="$(field version)" build="$(field build)" zip_name="$(field zip)" notarized="$(field notarized)"
app="$dir/export/WireTuner.app"
info="$app/Contents/Info.plist"
feed="$(plist_value "$info" SUFeedURL)"
public_key="$(plist_value "$info" SUPublicEDKey)"
minimum="$(plist_value "$info" LSMinimumSystemVersion)"
zip="$dir/dist/$zip_name"
[ -f "$zip" ] || die "no $zip"
case "$feed" in https://*/appcast.xml) ;; *) die "the app's SUFeedURL '$feed' is not an https appcast" ;; esac
base_url="${feed%/appcast.xml}"
channel="${base_url##*/}"
case "${WT_APPCAST_ENCLOSURE:-github}" in
github) enclosure_url="https://github.com/$repo/releases/download/$name/$zip_name" ;;
r2) enclosure_url="$base_url/$zip_name" ;;
*) die "WT_APPCAST_ENCLOSURE is github or r2" ;;
esac
publishable=true
[ "$notarized" = true ] || publishable=false

# --- notes ---------------------------------------------------------------------------------------
notes="${WT_RELEASE_NOTES:-}"
if [ -z "$notes" ]; then
    for candidate in "$release_root/docs/release-notes/$version-$build.md" "$release_root/docs/release-notes/$version.md"; do
        if [ -f "$candidate" ]; then notes="$candidate"; break; fi
    done
fi
if [ -z "$notes" ] || [ ! -f "$notes" ]; then
    [ "$publishable" = false ] || die "no release notes: write docs/release-notes/$version.md (or set WT_RELEASE_NOTES)"
    notes="$dir/notes.md"
    printf 'A test build of WireTuner %s (%s).  No release notes were written for it.\n' "$version" "$build" >"$notes"
    warn "no release notes for $version: using a placeholder"
fi

# --- base appcast --------------------------------------------------------------------------------
base_source="${WT_APPCAST_BASE:-$feed}"
base="$dir/appcast-base.xml"
case "$base_source" in
http://* | https://*)
    code="$(curl -sS -L --max-time 30 -o "$base" -w '%{http_code}' "$base_source" 2>"$dir/appcast-fetch.err" || true)"
    if [ "$code" = 200 ]; then
        say "base appcast: $base_source"
    elif [ "$code" = 404 ]; then
        say "no appcast at $base_source yet: starting one"
        rm -f "$base"
    elif [ "$publishable" = true ]; then
        die "could not fetch $base_source (HTTP ${code:-none}: $(cat "$dir/appcast-fetch.err")); set WT_APPCAST_BASE to a copy"
    else
        warn "could not fetch $base_source (HTTP ${code:-none}): the test appcast starts empty"
        rm -f "$base"
    fi
    ;;
*)
    [ -f "$base_source" ] || die "WT_APPCAST_BASE $base_source does not exist"
    cp "$base_source" "$base"
    ;;
esac

# --- signature -----------------------------------------------------------------------------------
bin="$(sparkle_bin)"
have_key=false
sign_args=()
if [ -n "${WT_SPARKLE_KEY_FILE:-}" ]; then
    [ -f "$WT_SPARKLE_KEY_FILE" ] || die "WT_SPARKLE_KEY_FILE does not name a file"
    sign_args=(--ed-key-file "$WT_SPARKLE_KEY_FILE")
    have_key=true
elif [ -n "$bin" ] && "$bin/generate_keys" ${WT_SPARKLE_KEY_ACCOUNT:+--account "$WT_SPARKLE_KEY_ACCOUNT"} -p >/dev/null 2>&1; then
    if [ -n "${WT_SPARKLE_KEY_ACCOUNT:-}" ]; then sign_args=(--account "$WT_SPARKLE_KEY_ACCOUNT"); fi
    have_key=true
fi
signature=""
if [ "$have_key" = true ]; then
    [ -n "$bin" ] || die "Sparkle's sign_update not found (set WT_SPARKLE_BIN)"
    [ -n "$public_key" ] || die "the app has no SUPublicEDKey, so no signature could be checked against it"
    signature="$("$bin/sign_update" ${sign_args[@]+"${sign_args[@]}"} -p "$zip" | tr -d '[:space:]')"
    [ -n "$signature" ] || die "sign_update gave no signature"
    verified=0
    "$(dirname "$0")/verify-signature.sh" "$zip" "$signature" "$public_key" || verified=$?
    case "$verified" in
    0) say "zip signed (EdDSA), and verified against the app's SUPublicEDKey" ;;
    2) warn "zip signed (EdDSA); not checked against the app's SUPublicEDKey (no OpenSSL with Ed25519)" ;;
    *) die "the signature does not verify with the app's SUPublicEDKey: the signing key and the embedded public key differ" ;;
    esac
else
    warn "no Sparkle signing key (the keychain's, or WT_SPARKLE_KEY_FILE): the appcast is unsigned"
    publishable=false
fi

# --- write ---------------------------------------------------------------------------------------
out="$dir/dist/appcast.xml"
flags=()
[ "$publishable" = true ] || flags+=(--unsigned)
python3 "$(dirname "$0")/appcast.py" --base "$([ -f "$base" ] && echo "$base")" --out "$out" --feed "$feed" \
    --channel "$channel" --version "$version" --build "$build" --url "$enclosure_url" \
    --length "$(stat -f %z "$zip")" --signature "$signature" --minimum-system "$minimum" --notes "$notes" \
    ${flags[@]+"${flags[@]}"}
if [ "$publishable" = true ]; then
    "$bin/sign_update" ${sign_args[@]+"${sign_args[@]}"} "$out" >/dev/null
    "$bin/sign_update" ${sign_args[@]+"${sign_args[@]}"} --verify "$out" >/dev/null || die "the signed appcast does not verify"
    say "appcast (signed) -> $out"
else
    loud "UNSIGNED TEST APPCAST -> $out" "Not signed for publishing (test build or no Sparkle key); the upload refuses it."
fi
