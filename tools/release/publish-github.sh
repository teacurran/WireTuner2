#!/usr/bin/env bash
# `make release-publish [PUBLISH=1]`: the release as a GitHub release on teacurran/WireTuner2
# (docs/spec/releasing.adoc, "GitHub Releases"; D-080).
#
#     tools/release/publish-github.sh             # dry run: checks, prints the notes and the gh call
#     tools/release/publish-github.sh --publish   # creates (or resumes) the release
#
# Tag and title "YYYY.MM.DD-NNN" (release.json's name, chosen by `make release`), assets the DMG,
# the zip and SHA256SUMS.txt, the tag made at the commit the build came from.  A build that is not
# notarized is a pre-release, and its notes open with how to get past Gatekeeper; WT_RELEASE_PRERELEASE=1
# makes a notarized build a pre-release too.  The notes (the owner's format of 2026.09.28-001): a line
# naming the build and commit, a Download section, the Gatekeeper steps when not notarized, then the
# release notes -- WT_RELEASE_NOTES, else docs/release-notes/<name>.md, <version>-<build>.md or
# <version>.md.  Needs gh signed in (`gh auth login`) with write access.
#
# Publishing is resumable: the release is made as a draft, each asset is uploaded with retries
# (WT_PUBLISH_ATTEMPTS, default 4, waiting WT_PUBLISH_RETRY_DELAY seconds, default 5, doubling),
# the uploaded sizes are checked against the local files, and only then is the draft published.  A
# release or draft already under the name (an interrupted run) is resumed: its title and notes are
# set again and missing or wrong-sized assets are uploaded with --clobber.  Nothing is ever deleted.
source "$(dirname "$0")/common.sh"

publish=false
case "${1:-}" in
--publish) publish=true ;;
"" | --dry-run) ;;
*) die "usage: $0 [--publish]" ;;
esac

dir="$(release_dir)"
manifest="$dir/release.json"
[ -f "$manifest" ] || die "no $manifest: run make release first"
field() { plutil -extract "$1" raw -o - "$manifest"; }
name="$(field name)" repo="$(field repo)" version="$(field version)" build="$(field build)"
commit="$(field commit)" notarized="$(field notarized)" signing="$(field signing)"
release_repo="$repo" # release_name_taken looks at the repository the release goes to
dist="$dir/dist"
assets=("$dist/$(field dmg)" "$dist/$(field zip)" "$dist/SHA256SUMS.txt")
for file in "${assets[@]}"; do [ -f "$file" ] || die "missing $file"; done
(cd "$dist" && shasum -a 256 -c SHA256SUMS.txt >/dev/null) || die "the files do not match SHA256SUMS.txt"

attempts="${WT_PUBLISH_ATTEMPTS:-4}" delay="${WT_PUBLISH_RETRY_DELAY:-5}"
[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || die "WT_PUBLISH_ATTEMPTS must be a positive number"
[[ "$delay" =~ ^[0-9]+$ ]] || die "WT_PUBLISH_RETRY_DELAY must be a number of seconds"

# `retry WHAT COMMAND...`: runs COMMAND up to $attempts times, waiting $delay, 2*$delay, ... between.
retry() {
    local what="$1" attempt=1 wait="$delay"
    shift
    until "$@"; do
        if [ "$attempt" -ge "$attempts" ]; then
            warn "$what failed $attempts times"
            return 1
        fi
        warn "$what failed (attempt $attempt of $attempts); retrying in ${wait}s"
        sleep "$wait"
        attempt=$((attempt + 1)) wait=$((wait * 2))
    done
}

# The release already on GitHub under the name, as `gh release view --json` gives it: sets
# remote_json ("" when there is none).  A lookup that fails for another reason (the network) fails,
# so `lookup_remote` retries it rather than taking it for "no release".
remote_json=""
fetch_remote() {
    local out err status=0
    err="$(mktemp)"
    out="$(gh release view "$name" --repo "$repo" --json isDraft,targetCommitish,assets 2>"$err")" || status=$?
    remote_json=""
    if [ "$status" = 0 ]; then
        remote_json="$out"
    elif grep -qi 'not found' "$err"; then
        status=0
    else
        cat "$err" >&2
        status=1
    fi
    rm -f "$err"
    return "$status"
}
lookup_remote() { retry "looking up the release $name" fetch_remote || die "cannot tell whether $name exists on $repo"; }
remote_field() { # remote_field isDraft|targetCommitish
    [ -n "$remote_json" ] || return 0
    printf '%s' "$remote_json" | python3 -c 'import json, sys; v = json.load(sys.stdin)[sys.argv[1]]; print(str(v).lower() if isinstance(v, bool) else v)' "$1"
}
# The size of the uploaded asset NAME on the release, empty when missing or not fully uploaded.
remote_size() {
    [ -n "$remote_json" ] || return 0
    printf '%s' "$remote_json" | python3 -c '
import json, sys
for asset in json.load(sys.stdin).get("assets") or []:
    if asset.get("name") == sys.argv[1] and asset.get("state", "uploaded") == "uploaded":
        print(asset.get("size"))
' "$1"
}
local_size() { wc -c <"$1" | tr -d ' '; }

problems=()
existing=none
if command -v gh >/dev/null; then
    if [ "$publish" = true ]; then
        lookup_remote
    else
        fetch_remote 2>/dev/null || true
    fi
    if [ -n "$remote_json" ]; then
        if [ "$(remote_field isDraft)" = true ]; then existing=draft; else existing=published; fi
        target="$(remote_field targetCommitish)"
        if [ "$target" != "$commit" ]; then
            problems+=("the $existing release $name on $repo is at '$target', not this build's commit $commit (make release again for the next number, or remove that release on GitHub by hand)")
        fi
    elif release_name_taken "$name"; then
        problems+=("$name is already a tag (make release again for the next number)")
    fi
else
    problems+=("gh is not installed (brew install gh)")
fi
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || problems+=("the build's commit is '$commit': build from a clean checkout of a pushed commit")

prerelease=false
if [ "$notarized" != true ] || [ "${WT_RELEASE_PRERELEASE:-}" = 1 ]; then prerelease=true; fi

notes_source="${WT_RELEASE_NOTES:-}"
if [ -z "$notes_source" ]; then
    for candidate in "$release_root/docs/release-notes/$name.md" "$release_root/docs/release-notes/$version-$build.md" "$release_root/docs/release-notes/$version.md"; do
        if [ -f "$candidate" ]; then notes_source="$candidate"; break; fi
    done
fi
[ -n "$notes_source" ] && [ -f "$notes_source" ] || problems+=("no release notes (docs/release-notes/$version.md or WT_RELEASE_NOTES)")

notes="$dir/github-notes.md"
dmg_name="$(field dmg)" zip_name="$(field zip)"
{
    if [ "$notarized" = true ]; then kind="a beta"; else kind="a pre-release for trying the app"; fi
    printf 'WireTuner %s for macOS -- %s, built from commit `%s`.\n\n' "$name" "$kind" "${commit:0:7}"
    printf '## Download\n'
    printf -- '- **%s** -- open it and drag WireTuner to Applications.\n' "$dmg_name"
    printf -- '- **%s** -- the same app, zipped.\n' "$zip_name"
    printf -- '- Version %s (build %s). Universal (Apple silicon and Intel), macOS 15 or later. Checksums: SHA256SUMS.txt.\n\n' "$version" "$build"
    if [ "$notarized" != true ]; then
        cat <<'TEXT'
## Opening it the first time
This build is **not signed with a Developer ID or notarized yet**, so macOS will refuse to open it with a double-click. To open it:
1. In Finder, Control-click (right-click) WireTuner in Applications and choose **Open**, then **Open** again in the dialog, **or**
2. In Terminal: `xattr -dr com.apple.quarantine /Applications/WireTuner.app`

You only need to do this once.

TEXT
    fi
    # The notes file's own "# title" line is for Sparkle's window; GitHub has the release title.
    if [ -n "$notes_source" ] && [ -f "$notes_source" ]; then sed '1{/^# /d;}' "$notes_source"; fi
} >"$notes"

release_flags=(--repo "$repo" --title "WireTuner $name" --notes-file "$notes")
create=(gh release create "$name" --draft "${release_flags[@]}" --target "$commit")
update=(gh release edit "$name" "${release_flags[@]}")
if [ "$prerelease" = true ]; then
    create+=(--prerelease) update+=(--prerelease)
else
    update+=(--prerelease=false) # a resumed release may have been made as a pre-release
fi
finish=(gh release edit "$name" --repo "$repo" --draft=false)

# `create_draft`: one attempt at the draft.  A create that timed out may still have made it, so a
# failed attempt looks first and counts a draft that is there as made (no second draft).
create_draft() {
    "${create[@]}" && return 0
    lookup_remote
    [ -n "$remote_json" ]
}
upload() { gh release upload "$name" "$1" --repo "$repo" --clobber; }

if [ "$publish" = true ]; then
    if [ ${#problems[@]} -gt 0 ]; then
        printf '  - %s\n' "${problems[@]}" >&2
        die "refusing to publish $name"
    fi
    gh api "repos/$repo/commits/$commit" >/dev/null 2>&1 || die "commit $commit is not on $repo: push it first"
    kind_text="$([ "$prerelease" = true ] && echo ' (pre-release)')"
    case "$existing" in
    none)
        say "creating the draft GitHub release $name on $repo$kind_text"
        retry "creating the draft $name" create_draft || die "could not create the draft $name; run again to resume"
        ;;
    *)
        say "resuming the $existing GitHub release $name on $repo$kind_text"
        retry "setting the title and notes of $name" "${update[@]}" || die "could not update $name; run again to resume"
        ;;
    esac
    lookup_remote
    for file in "${assets[@]}"; do
        base="$(basename "$file")" size="$(local_size "$file")"
        if [ "$(remote_size "$base")" = "$size" ]; then
            say "$base is already uploaded ($size bytes)"
            continue
        fi
        say "uploading $base ($size bytes)"
        retry "uploading $base" upload "$file" || die "could not upload $base; the draft $name is kept: run again to resume"
    done
    lookup_remote
    mismatched=()
    for file in "${assets[@]}"; do
        base="$(basename "$file")" size="$(local_size "$file")" uploaded="$(remote_size "$base")"
        [ "$uploaded" = "$size" ] || mismatched+=("$base: ${uploaded:-missing} on GitHub, $size here")
    done
    if [ ${#mismatched[@]} -gt 0 ]; then
        printf '  - %s\n' "${mismatched[@]}" >&2
        die "the uploaded assets do not match; $name is left as it is: run again to resume"
    fi
    if [ "$(remote_field isDraft)" = true ]; then
        say "publishing $name"
        retry "publishing $name" "${finish[@]}" || die "could not publish the draft $name; run again to resume"
    fi
    say "published $name: https://github.com/$repo/releases/tag/$name"
else
    say "dry run (make release-publish PUBLISH=1 publishes): $name on $repo, signing $signing, notarized $notarized, pre-release $prerelease, existing release: $existing"
    if [ ${#problems[@]} -gt 0 ]; then
        warn "a real publish would refuse this release:"
        printf '  - %s\n' "${problems[@]}" >&2
    fi
    if [ "$existing" = none ]; then plan=("${create[@]}"); else plan=("${update[@]}"); fi
    printf ' '
    printf ' %q' "${plan[@]}"
    printf '\n'
    for file in "${assets[@]}"; do
        printf '  gh release upload %q %q --repo %q --clobber\n' "$name" "$file" "$repo"
    done
    printf ' '
    printf ' %q' "${finish[@]}"
    printf '\n--- notes (%s) ---\n' "$notes"
    cat "$notes"
fi
