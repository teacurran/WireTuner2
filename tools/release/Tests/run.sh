#!/usr/bin/env bash
# Tests for tools/release (`make release-tools-test`): the version file, the appcast writer, the
# appcast, upload and GitHub publish scripts against a fabricated release directory (a stateful
# stubbed gh: retried uploads, a resumed draft, a wrong-sized asset), and the signature check.
# A throwaway Ed25519 key is made for the run; nothing touches the keychain, the network or R2.
# Needs Sparkle's sign_update (any resolved WireTuner DerivedData, or WT_SPARKLE_BIN) and an
# OpenSSL with Ed25519 (Homebrew's openssl@3).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tools="$here/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

source "$tools/common.sh"
bin="$(sparkle_bin)"
[ -n "$bin" ] || fail "Sparkle's sign_update not found (build the app once, or set WT_SPARKLE_BIN)"
export WT_SPARKLE_BIN="$bin"
openssl=""
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl "$(command -v openssl)"; do
    if [ -x "$candidate" ] && "$candidate" genpkey -algorithm ed25519 -out /dev/null 2>/dev/null; then openssl="$candidate"; break; fi
done
[ -n "$openssl" ] || fail "no OpenSSL with Ed25519 (brew install openssl@3)"
unset WT_SPARKLE_PUBLIC_KEY WT_SPARKLE_KEY_ACCOUNT WT_RELEASE_NOTES WT_R2_BUCKET WT_R2_ENDPOINT WT_R2_ACCOUNT_ID WT_R2_PROFILE

# A throwaway key pair in Sparkle's format: the base64 32-byte seed, the base64 32-byte public key.
key_pair() { # key_pair NAME
    "$openssl" genpkey -algorithm ed25519 -outform DER -out "$work/$1.der"
    "$openssl" pkey -inform DER -in "$work/$1.der" -pubout -outform DER -out "$work/$1.pub.der"
    tail -c 32 "$work/$1.der" | base64 >"$work/$1.key"
    tail -c 32 "$work/$1.pub.der" | base64
}
public="$(key_pair signing)"
other_public="$(key_pair other)"

# --- version.sh ----------------------------------------------------------------------------------
cp "$release_version_file" "$work/Version.xcconfig"
version() { WT_VERSION_FILE="$work/Version.xcconfig" "$tools/version.sh" "$@"; }
sed -i '' 's/^MARKETING_VERSION = .*/MARKETING_VERSION = 0.1.9/; s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = 41/' "$work/Version.xcconfig"
[ "$(version show)" = "0.1.9 (41)" ] || fail "show"
[ "$(version bump-build)" = "0.1.9 (42)" ] || fail "bump-build"
[ "$(version bump-version)" = "0.1.10 (43)" ] || fail "bump-version with no argument bumps the patch"
[ "$(version bump-version 0.2.0)" = "0.2.0 (44)" ] || fail "bump-version 0.2.0"
if version bump-version 0.1.99 2>/dev/null; then fail "a lower version must be refused"; fi
if version bump-version 0.3 2>/dev/null; then fail "a version that is not X.Y.Z must be refused"; fi
grep -q '^CURRENT_PROJECT_VERSION = 44$' "$work/Version.xcconfig" || fail "the build number was not written"
grep -q '^// The version of WireTuner' "$work/Version.xcconfig" || fail "the comments were lost"
ok "version.sh"

# --- appcast.py ----------------------------------------------------------------------------------
cat >"$work/notes.md" <<'EOF'
# Beta 3

Fixes for *snapping* and **type**, with `code` & <tags>.

- One
- Two, with [a link](https://example.com/a?b=1&c=2)
  continued
1. First step
EOF
feed="https://updates.example.com/wiretuner/beta/appcast.xml"
appcast() { python3 "$tools/appcast.py" --feed "$feed" --channel beta --version "$1" --build "$2" \
    --url "https://updates.example.com/wiretuner/beta/WireTuner-$1-$2.zip" --length 10 --signature "sig$2" \
    --minimum-system 15.0 --notes "$work/notes.md" --pub-date "Mon, 28 Sep 2026 12:00:00 GMT" "${@:3}"; }
appcast 0.1.0 7 --base '' --out "$work/a.xml"
appcast 0.1.0 8 --base "$work/a.xml" --out "$work/b.xml"
appcast 0.1.0 8 --base "$work/b.xml" --out "$work/c.xml"
python3 - "$work" <<'EOF'
import sys, xml.etree.ElementTree as ET
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
work = sys.argv[1]
b = ET.parse(work + "/b.xml").getroot().find("channel")
builds = [i.findtext(S + "version") for i in b.findall("item")]
assert builds == ["8", "7"], builds
item = b.find("item")
assert item.findtext(S + "shortVersionString") == "0.1.0"
assert item.findtext(S + "minimumSystemVersion") == "15.0"
enclosure = item.find("enclosure")
assert enclosure.get(S + "edSignature") == "sig8" and enclosure.get("length") == "10"
assert enclosure.get("url").endswith("/WireTuner-0.1.0-8.zip")
notes = item.findtext("description")
for fragment in ["<h2>Beta 3</h2>", "<em>snapping</em>", "<strong>type</strong>", "<code>code</code>",
                 "&amp; &lt;tags&gt;", "<ul>\n<li>One</li>", 'href="https://example.com/a?b=1&amp;c=2"',
                 "a link</a> continued</li>", "</ul>\n<ol>\n<li>First step</li>\n</ol>"]:
    assert fragment in notes, (fragment, notes)
assert b.findtext("title") == "WireTuner (beta)"
c = ET.parse(work + "/c.xml").getroot().find("channel")
assert [i.findtext(S + "version") for i in c.findall("item")] == ["8", "7"], "the same build replaces its item"
EOF
if appcast 0.1.0 6 --base "$work/b.xml" --out "$work/d.xml" 2>"$work/err"; then fail "an older build must be refused"; fi
grep -q 'not newer than build 8' "$work/err" || fail "the refusal names the newer build"
appcast 0.1.0 9 --base "$work/b.xml" --out "$work/e.xml" --unsigned
grep -q 'UNSIGNED TEST APPCAST' "$work/e.xml" || fail "--unsigned marks the appcast"
ok "appcast.py"

# --- verify-signature.sh -------------------------------------------------------------------------
echo payload >"$work/payload"
signature="$("$bin/sign_update" --ed-key-file "$work/signing.key" -p "$work/payload")"
WT_OPENSSL="$openssl" "$tools/verify-signature.sh" "$work/payload" "$signature" "$public" || fail "a good signature"
status=0
WT_OPENSSL="$openssl" "$tools/verify-signature.sh" "$work/payload" "$signature" "$other_public" || status=$?
[ "$status" = 1 ] || fail "another key's signature must not verify (got $status)"
ok "verify-signature.sh"

# --- appcast.sh and upload.sh on a fabricated release ---------------------------------------------
stem="WireTuner-2031.01.02-003"
commit="0123456789abcdef0123456789abcdef01234567"
release() { # release DIR NOTARIZED SIGNING PUBLIC_KEY [COMMIT]
    local dir="$1"
    mkdir -p "$dir/export/WireTuner.app/Contents" "$dir/dist"
    cat >"$dir/export/WireTuner.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>44</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>SUFeedURL</key><string>$feed</string>
<key>SUPublicEDKey</key><string>$4</string>
</dict></plist>
EOF
    head -c 5000 /dev/urandom >"$dir/dist/$stem.zip"
    head -c 7000 /dev/urandom >"$dir/dist/$stem.dmg"
    (cd "$dir/dist" && shasum -a 256 "$stem.dmg" "$stem.zip" >SHA256SUMS.txt)
    cat >"$dir/release.json" <<EOF
{"name": "2031.01.02-003", "repo": "owner/repo", "version": "0.2.0", "build": 44, "commit": "${5:-$commit}", "signing": "$3", "team": "", "notarized": $2,
 "feed": "$feed", "dmg": "$stem.dmg", "zip": "$stem.zip"}
EOF
}
S="{http://www.andymatuschak.org/xml-namespaces/sparkle}"

# A notarized release, the key file, a base with build 8: a signed appcast a real upload accepts.
release "$work/good" true developer-id "$public"
WT_RELEASE_DIR="$work/good" WT_SPARKLE_KEY_FILE="$work/signing.key" WT_APPCAST_BASE="$work/b.xml" \
    WT_RELEASE_NOTES="$work/notes.md" WT_OPENSSL="$openssl" "$tools/appcast.sh" >"$work/out" 2>&1 || { cat "$work/out"; fail "appcast.sh on a good release"; }
out="$work/good/dist/appcast.xml"
grep -q 'UNSIGNED' "$out" && fail "a good release's appcast must not be marked unsigned"
"$bin/sign_update" --ed-key-file "$work/signing.key" --verify "$out" >/dev/null || fail "the feed signature"
enclosure_signature="$(python3 -c "import sys,xml.etree.ElementTree as E; i=E.parse(sys.argv[1]).getroot().find('channel/item'); print(i.find('enclosure').get('$S'+'edSignature'))" "$out")"
WT_OPENSSL="$openssl" "$tools/verify-signature.sh" "$work/good/dist/$stem.zip" "$enclosure_signature" "$public" || fail "the enclosure signature"
grep -q "https://github.com/owner/repo/releases/download/2031.01.02-003/$stem.zip" "$out" || fail "the enclosure is the GitHub asset"
grep -q 'length="5000"' "$out" || fail "the enclosure length"
[ "$(grep -c '<item>' "$out")" = 3 ] || fail "the base's items are kept"
ok "appcast.sh signs, verifies and keeps the base"
cp -R "$work/good" "$work/r2"
WT_RELEASE_DIR="$work/r2" WT_APPCAST_ENCLOSURE=r2 WT_SPARKLE_KEY_FILE="$work/signing.key" WT_APPCAST_BASE="$work/b.xml" \
    WT_RELEASE_NOTES="$work/notes.md" WT_OPENSSL="$openssl" "$tools/appcast.sh" >"$work/out" 2>&1 || { cat "$work/out"; fail "appcast.sh, R2 enclosure"; }
grep -q "https://updates.example.com/wiretuner/beta/$stem.zip" "$work/r2/dist/appcast.xml" || fail "WT_APPCAST_ENCLOSURE=r2"
ok "the R2 enclosure"

# Upload: the dry run prints the five copies, appcast last, and sends nothing.
WT_RELEASE_DIR="$work/good" WT_R2_BUCKET=bucket WT_R2_ACCOUNT_ID=acct PATH="$work/noaws:$PATH" "$tools/upload.sh" >"$work/dry" 2>&1 || { cat "$work/dry"; fail "dry run"; }
[ "$(grep -c "aws s3 cp --endpoint-url https://acct.r2.cloudflarestorage.com" "$work/dry")" = 5 ] || { cat "$work/dry"; fail "dry run prints five copies"; }
tail -n 1 "$work/dry" | grep -q 's3://bucket/wiretuner/beta/appcast.xml' || fail "the appcast goes last"
grep -q 's3://bucket/wiretuner/beta/WireTuner-beta.dmg' "$work/dry" || fail "the fixed-name DMG"
grep -q 'refuse' "$work/dry" && fail "a good release draws no refusal"
# A real upload with a stub aws that records its calls.
mkdir -p "$work/stub"
printf '#!/bin/sh\necho "$@" >> "%s/aws.log"\n' "$work" >"$work/stub/aws"
chmod +x "$work/stub/aws"
printf '#!/bin/sh\necho "$@" >> "%s/curl.log"\necho 200\n' "$work" >"$work/stub/curl"
chmod +x "$work/stub/curl"
WT_RELEASE_DIR="$work/good" WT_R2_BUCKET=bucket WT_R2_ENDPOINT=https://r2.example PATH="$work/stub:$PATH" "$tools/upload.sh" --upload >"$work/up" 2>&1 || { cat "$work/up"; fail "upload"; }
[ "$(wc -l <"$work/aws.log" | tr -d ' ')" = 5 ] || fail "five uploads"
grep -q "https://github.com/owner/repo/releases/download/2031.01.02-003/$stem.zip" "$work/curl.log" || fail "the GitHub asset is checked before the upload"
grep -q "s3://bucket/wiretuner/beta/$stem.sha256" "$work/aws.log" || fail "the checksums key"
tail -n 1 "$work/aws.log" | grep -q 'appcast.xml' || fail "the appcast is uploaded last"
grep -q 'cache-control public, max-age=300' "$work/aws.log" || fail "the appcast's short cache"
if WT_RELEASE_DIR="$work/good" WT_R2_ENDPOINT=https://r2.example PATH="$work/stub:$PATH" "$tools/upload.sh" --upload >/dev/null 2>&1; then fail "no bucket must refuse"; fi
ok "upload.sh dry run and upload"

# A test build: the appcast is marked, and a real upload refuses it before any copy.
release "$work/test" false unsigned ""
WT_RELEASE_DIR="$work/test" WT_APPCAST_BASE="$work/b.xml" WT_RELEASE_NOTES="$work/notes.md" "$tools/appcast.sh" >"$work/out" 2>&1 || { cat "$work/out"; fail "appcast.sh on a test build"; }
grep -q 'UNSIGNED TEST APPCAST' "$work/test/dist/appcast.xml" || fail "a test build's appcast is marked"
rm -f "$work/aws.log"
if WT_RELEASE_DIR="$work/test" WT_R2_BUCKET=bucket WT_R2_ENDPOINT=https://r2.example PATH="$work/stub:$PATH" "$tools/upload.sh" --upload 2>"$work/err"; then fail "a test build must not upload"; fi
grep -q 'not notarized' "$work/err" || fail "the refusal says why"
[ ! -e "$work/aws.log" ] || fail "a refused upload sent something"
ok "a test build is never published"

# The signing key and the app's public key differ: nothing is written.
release "$work/mismatch" true developer-id "$other_public"
if WT_RELEASE_DIR="$work/mismatch" WT_SPARKLE_KEY_FILE="$work/signing.key" WT_APPCAST_BASE="$work/b.xml" \
    WT_RELEASE_NOTES="$work/notes.md" WT_OPENSSL="$openssl" "$tools/appcast.sh" >"$work/out" 2>&1; then fail "a key mismatch must fail"; fi
grep -q 'keys* differ\|embedded public key differ' "$work/out" || { cat "$work/out"; fail "the mismatch message"; }
[ ! -e "$work/mismatch/dist/appcast.xml" ] || fail "a mismatch wrote an appcast"
ok "a signing key that is not the app's is refused"

# A notarized release without notes: refused.
if WT_RELEASE_DIR="$work/good" WT_SPARKLE_KEY_FILE="$work/signing.key" WT_APPCAST_BASE="$work/b.xml" \
    WT_RELEASE_NOTES="$work/none.md" WT_OPENSSL="$openssl" "$tools/appcast.sh" >"$work/out" 2>&1; then fail "missing notes must fail"; fi
grep -q 'no release notes' "$work/out" || fail "the missing-notes message"
ok "a release without notes is refused"


# --- release names ---------------------------------------------------------------------------------
mkdir -p "$work/ghstub"
# A gh that keeps releases under $GH_STATE/<tag>/ (draft, target, title, assets/<file> holding the
# uploaded size) and logs every release call to $work/gh.log.  $GH_STATE/fail-<verb> holds how many
# of the next `release <verb>` calls fail (a create that fails after making the draft with
# fail-create-after); $GH_STATE/short-upload makes every upload land one byte short.
export GH_STATE="$work/ghstate" GH_LOG="$work/gh.log"
cat >"$work/ghstub/gh" <<'STUB'
#!/bin/bash
set -eu
failing() { # failing VERB: consumes one injected failure
    local file="$GH_STATE/fail-$1" n
    [ -f "$file" ] || return 1
    n="$(cat "$file")"
    [ "$n" -gt 0 ] || return 1
    echo $((n - 1)) >"$file"
}
flag() { # flag NAME ARGS...: the value of --NAME VALUE
    local name="$1"; shift
    while [ $# -gt 0 ]; do
        if [ "$1" = "--$name" ]; then echo "$2"; return 0; fi
        shift
    done
}
case "$1 $2" in
"release list")
    printf '2031.01.02-001\n2031.01.02-004\n2031.01.03-009\nv1\n'
    for d in "$GH_STATE"/*/; do [ -d "$d" ] && basename "$d"; done
    ;;
"api repos/owner/repo/tags"*) printf '2031.01.02-002\n' ;;
"api repos/owner/repo/commits/"*) exit 0 ;;
"release view")
    rel="$GH_STATE/$3"
    [ -d "$rel" ] || { echo "release not found" >&2; exit 1; }
    python3 - "$rel" <<'EOF'
import json, os, sys
rel = sys.argv[1]
read = lambda name: open(os.path.join(rel, name)).read().strip()
assets = [{"name": n, "size": int(read("assets/" + n)), "state": "uploaded"} for n in sorted(os.listdir(os.path.join(rel, "assets")))]
print(json.dumps({"isDraft": read("draft") == "true", "targetCommitish": read("target"), "assets": assets}))
EOF
    ;;
"release create")
    echo "$@" >>"$GH_LOG"
    if failing create; then echo "dial tcp: lookup api.github.com: i/o timeout" >&2; exit 1; fi
    rel="$GH_STATE/$3"
    mkdir -p "$rel/assets"
    echo true >"$rel/draft"
    flag target "$@" >"$rel/target"
    flag title "$@" >"$rel/title"
    if failing create-after; then echo "dial tcp: lookup api.github.com: i/o timeout" >&2; exit 1; fi
    ;;
"release upload")
    echo "$@" >>"$GH_LOG"
    if failing upload; then echo "dial tcp: lookup uploads.github.com: i/o timeout" >&2; exit 1; fi
    rel="$GH_STATE/$3"
    size="$(wc -c <"$4" | tr -d ' ')"
    [ -f "$GH_STATE/short-upload" ] && size=$((size - 1))
    echo "$size" >"$rel/assets/$(basename "$4")"
    ;;
"release edit")
    echo "$@" >>"$GH_LOG"
    if failing edit; then echo "HTTP 502" >&2; exit 1; fi
    rel="$GH_STATE/$3"
    for arg in "$@"; do [ "$arg" = --draft=false ] && echo false >"$rel/draft"; done
    title="$(flag title "$@")"
    [ -z "$title" ] || echo "$title" >"$rel/title"
    ;;
"release delete")
    echo "$@" >>"$GH_LOG"
    rm -rf "${GH_STATE:?}/$3"
    ;;
*) exit 0 ;;
esac
STUB
chmod +x "$work/ghstub/gh"
mkdir -p "$GH_STATE"
names() { (cd "$work" && PATH="$work/ghstub:$PATH" WT_GITHUB_REPO=owner/repo WT_RELEASE_DATE="$1" bash -c "source '$tools/common.sh'; next_release_name"); }
[ "$(names 2031.01.02)" = 2031.01.02-005 ] || fail "the next name after 004 (got $(names 2031.01.02))"
[ "$(names 2031.01.04)" = 2031.01.04-001 ] || fail "a new day starts at 001"
if (PATH="$work/ghstub:$PATH" WT_RELEASE_DATE=2031-01-02 bash -c "source '$tools/common.sh'; next_release_name" 2>/dev/null); then fail "a malformed date"; fi
(PATH="$work/ghstub:$PATH" WT_GITHUB_REPO=owner/repo bash -c "source '$tools/common.sh'; release_name_taken 2031.01.02-004") || fail "a taken name"
ok "release names YYYY.MM.DD-NNN"

# --- publish-github.sh -----------------------------------------------------------------------------
export WT_PUBLISH_RETRY_DELAY=0
publish() { WT_RELEASE_DIR="$1" WT_RELEASE_NOTES="$work/notes.md" PATH="$work/ghstub:$PATH" "$tools/publish-github.sh" "${@:2}"; }
tag="2031.01.02-003"
fresh() { rm -rf "$GH_STATE" "$GH_LOG"; mkdir -p "$GH_STATE"; } # no releases, no failures
draft() { # draft FILE=SIZE...: an interrupted run's draft at the build's commit
    mkdir -p "$GH_STATE/$tag/assets"
    echo true >"$GH_STATE/$tag/draft"
    echo "$commit" >"$GH_STATE/$tag/target"
    local spec
    for spec in "$@"; do echo "${spec#*=}" >"$GH_STATE/$tag/assets/${spec%%=*}"; done
}
size_of() { wc -c <"$1" | tr -d ' '; }
calls() { if [ -f "$GH_LOG" ]; then grep -c "^release $1 " "$GH_LOG" || true; else echo 0; fi; } # calls VERB
published() { [ "$(cat "$GH_STATE/$tag/draft")" = false ]; }
never_deleted() { [ "$(calls delete)" = 0 ] && [ -d "$GH_STATE/$tag" ]; }
matches_local() { # every asset on the release is the local file's size
    local file
    for file in "$1/dist/$stem.dmg" "$1/dist/$stem.zip" "$1/dist/SHA256SUMS.txt"; do
        [ "$(cat "$GH_STATE/$tag/assets/$(basename "$file")")" = "$(size_of "$file")" ] || return 1
    done
}

fresh
publish "$work/test" >"$work/pub" 2>&1 || { cat "$work/pub"; fail "publish dry run"; }
grep -q -- '--prerelease' "$work/pub" || fail "an unsigned build is a pre-release"
grep -q 'Opening it the first time' "$work/pub" || fail "an unsigned build's notes say how to open it"
grep -q "^## Download" "$work/pub" || fail "the notes have a Download section"
grep -q "^# Beta 3" "$work/pub" && fail "the notes file title is dropped"
grep -q "gh release create $tag --draft --repo owner/repo --title WireTuner" "$work/pub" || { cat "$work/pub"; fail "the gh call"; }
for file in "$stem.dmg" "$stem.zip" SHA256SUMS.txt; do
    grep -q "gh release upload $tag .*$file --repo owner/repo --clobber" "$work/pub" || fail "the dry run names the upload of $file"
done
grep -q "gh release edit $tag --repo owner/repo --draft=false" "$work/pub" || fail "the dry run names the publish"
[ ! -e "$GH_LOG" ] || fail "a dry run called gh release"
publish "$work/test" --publish >"$work/pub" 2>&1 || { cat "$work/pub"; fail "publish"; }
grep -q -- "--target $commit --prerelease" "$GH_LOG" || fail "the release is made at the build's commit"
[ "$(calls create)" = 1 ] && [ "$(calls upload)" = 3 ] || fail "one draft, three uploads"
tail -n 1 "$GH_LOG" | grep -q -- '--draft=false' || fail "the draft is published last"
published && matches_local "$work/test" || fail "a published release with every asset"
fresh
publish "$work/good" >"$work/pub" 2>&1
grep -qE -- '--prerelease( |$)' "$work/pub" && fail "a notarized build is a full release"
grep -q 'Opening it the first time' "$work/pub" && fail "a notarized build needs no Gatekeeper steps"
release "$work/dirty" false unsigned "" "0123abc-dirty"
if publish "$work/dirty" --publish >"$work/pub" 2>&1; then fail "a build from a dirty tree must not publish"; fi
grep -q 'clean checkout' "$work/pub" || fail "the dirty-tree refusal"
ok "publish-github.sh"

# A failed upload (the 2026-09-29 DNS timeout) is retried; so is a create that timed out after
# making the draft, without a second draft.
fresh
echo 2 >"$GH_STATE/fail-upload"
echo 1 >"$GH_STATE/fail-create-after"
publish "$work/test" --publish >"$work/pub" 2>&1 || { cat "$work/pub"; fail "publish with failing uploads"; }
[ "$(calls upload)" = 5 ] || { cat "$GH_LOG"; fail "two failed uploads retried (got $(calls upload) uploads)"; }
[ "$(calls create)" = 1 ] || fail "a create that made the draft is not repeated"
grep -q 'failed (attempt 1 of 4); retrying' "$work/pub" || fail "the retry is reported"
published && matches_local "$work/test" && never_deleted || fail "published after the retries"
ok "a failed upload is retried"

# An upload that keeps failing: the draft is kept, not published and not deleted.
fresh
echo 9 >"$GH_STATE/fail-upload"
if publish "$work/test" --publish >"$work/pub" 2>&1; then fail "an upload failing every time must fail"; fi
[ "$(calls upload)" = 4 ] || fail "four attempts (got $(calls upload))"
grep -q 'run again to resume' "$work/pub" || fail "the failure says to run again"
! published && never_deleted || fail "the draft is kept as a draft"
ok "an upload that keeps failing keeps the draft"

# Run again: the draft from before (only SHA256SUMS.txt uploaded) is resumed -- no second create,
# notes and title set again, the missing assets uploaded, then published.
fresh
draft "SHA256SUMS.txt=$(size_of "$work/test/dist/SHA256SUMS.txt")"
publish "$work/test" >"$work/pub" 2>&1 || { cat "$work/pub"; fail "dry run on a draft"; }
grep -q 'existing release: draft' "$work/pub" || fail "the dry run names the draft"
grep -q "gh release edit $tag --repo owner/repo --title WireTuner.* --notes-file" "$work/pub" || fail "the dry run resumes the draft"
grep -q 'already a tag' "$work/pub" && fail "a draft is not a taken name"
publish "$work/test" --publish >"$work/pub" 2>&1 || { cat "$work/pub"; fail "resuming a draft"; }
[ "$(calls create)" = 0 ] || fail "a draft is resumed, not created again"
grep -q "^release edit $tag --repo owner/repo --title WireTuner $tag --notes-file .* --prerelease" "$GH_LOG" || { cat "$GH_LOG"; fail "the notes and title are set"; }
[ "$(calls upload)" = 2 ] || fail "only the two missing assets are uploaded (got $(calls upload))"
grep -q "SHA256SUMS.txt" <(grep '^release upload' "$GH_LOG") && fail "an uploaded asset of the right size is kept"
published && matches_local "$work/test" && never_deleted || fail "the resumed draft is published"
ok "an existing draft is resumed"

# A wrong-sized asset on the draft is uploaded again with --clobber.
fresh
draft "$stem.dmg=12" "$stem.zip=$(size_of "$work/test/dist/$stem.zip")" "SHA256SUMS.txt=$(size_of "$work/test/dist/SHA256SUMS.txt")"
publish "$work/test" --publish >"$work/pub" 2>&1 || { cat "$work/pub"; fail "a size mismatch"; }
[ "$(calls upload)" = 1 ] && grep -q "^release upload $tag .*$stem.dmg --repo owner/repo --clobber" "$GH_LOG" || { cat "$GH_LOG"; fail "the wrong-sized DMG is uploaded again"; }
published && matches_local "$work/test" && never_deleted || fail "published once the sizes match"
ok "a size mismatch is uploaded again"

# Sizes still wrong after uploading: not published, not deleted.
fresh
touch "$GH_STATE/short-upload"
if publish "$work/test" --publish >"$work/pub" 2>&1; then fail "sizes that do not match must not publish"; fi
grep -q "do not match" "$work/pub" && grep -q "$stem.dmg: $(( $(size_of "$work/test/dist/$stem.dmg") - 1 )) on GitHub" "$work/pub" || { cat "$work/pub"; fail "the mismatch is named"; }
[ "$(calls edit)" = 0 ] && ! published && never_deleted || fail "a mismatch leaves the draft alone"
ok "the uploaded sizes are checked before publishing"

# A draft at another commit, or a bare tag, is not this build's: refused, left alone.
fresh
draft
echo "fedcba9876543210fedcba9876543210fedcba98" >"$GH_STATE/$tag/target"
if publish "$work/test" --publish >"$work/pub" 2>&1; then fail "a draft at another commit must be refused"; fi
grep -q "not this build's commit" "$work/pub" || fail "the other-commit refusal"
[ ! -e "$GH_LOG" ] && never_deleted || fail "a refused draft is left alone"
release "$work/tagged" false unsigned ""
sed -i '' 's/"2031.01.02-003"/"2031.01.02-002"/' "$work/tagged/release.json"
if publish "$work/tagged" --publish >"$work/pub" 2>&1; then fail "a bare tag must be refused"; fi
grep -q 'already a tag' "$work/pub" || fail "the bare-tag refusal"
ok "a release that is not this build's is refused"

echo "release tools: all tests passed"
