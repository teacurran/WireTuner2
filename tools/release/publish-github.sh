#!/usr/bin/env bash
# `make release-publish [PUBLISH=1]`: the release as a GitHub release on teacurran/WireTuner2
# (docs/spec/releasing.adoc, "GitHub Releases"; D-080).
#
#     tools/release/publish-github.sh             # dry run: checks, prints the notes and the gh call
#     tools/release/publish-github.sh --publish   # creates the release
#
# Tag and title "YYYY.MM.DD-NNN" (release.json's name, chosen by `make release`), assets the DMG,
# the zip and SHA256SUMS.txt, the tag made at the commit the build came from.  A build that is not
# notarized is a pre-release, and its notes open with how to get past Gatekeeper; WT_RELEASE_PRERELEASE=1
# makes a notarized build a pre-release too.  The notes (the owner's format of 2026.09.28-001): a line
# naming the build and commit, a Download section, the Gatekeeper steps when not notarized, then the
# release notes -- WT_RELEASE_NOTES, else docs/release-notes/<name>.md, <version>-<build>.md or
# <version>.md.  Needs gh signed in (`gh auth login`) with write access.
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
dist="$dir/dist"
assets=("$dist/$(field dmg)" "$dist/$(field zip)" "$dist/SHA256SUMS.txt")
for file in "${assets[@]}"; do [ -f "$file" ] || die "missing $file"; done
(cd "$dist" && shasum -a 256 -c SHA256SUMS.txt >/dev/null) || die "the files do not match SHA256SUMS.txt"

problems=()
if release_name_taken "$name"; then problems+=("$name is already a tag or release (make release again for the next number)"); fi
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || problems+=("the build's commit is '$commit': build from a clean checkout of a pushed commit")
command -v gh >/dev/null || problems+=("gh is not installed (brew install gh)")

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

command=(gh release create "$name" "${assets[@]}" --repo "$repo" --title "WireTuner $name" --notes-file "$notes" --target "$commit")
if [ "$prerelease" = true ]; then command+=(--prerelease); fi

if [ "$publish" = true ]; then
    if [ ${#problems[@]} -gt 0 ]; then
        printf '  - %s\n' "${problems[@]}" >&2
        die "refusing to publish $name"
    fi
    gh api "repos/$repo/commits/$commit" >/dev/null 2>&1 || die "commit $commit is not on $repo: push it first"
    say "creating the GitHub release $name on $repo$([ "$prerelease" = true ] && echo ' (pre-release)')"
    "${command[@]}"
else
    say "dry run (make release-publish PUBLISH=1 publishes): $name on $repo, signing $signing, notarized $notarized, pre-release $prerelease"
    if [ ${#problems[@]} -gt 0 ]; then
        warn "a real publish would refuse this release:"
        printf '  - %s\n' "${problems[@]}" >&2
    fi
    printf ' '
    printf ' %q' "${command[@]}"
    printf '\n--- notes (%s) ---\n' "$notes"
    cat "$notes"
fi
