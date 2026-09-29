# Shared by the release scripts (docs/spec/releasing.adoc).  Sourced, not run.
#
# Credentials are read from the environment and the login keychain only; nothing here writes one
# to a file in the repository, and nothing echoes a secret.
#
#   WT_DEVELOPER_ID_IDENTITY   "Developer ID Application: <Name> (<TEAMID>)"; when unset, the one
#                              such identity in the keychain is used (several: set it)
#   WT_TEAM_ID                 the team; when unset, read from the identity's "(TEAMID)"
#   WT_NOTARY_PROFILE          an `xcrun notarytool store-credentials` keychain profile, or
#   WT_NOTARY_KEY_PATH, WT_NOTARY_KEY_ID, WT_NOTARY_ISSUER
#                              an App Store Connect API key (.p8 outside the repo; the issuer is
#                              omitted for an individual key)
#   WT_SPARKLE_PUBLIC_KEY      the EdDSA public key; when unset, `generate_keys -p` reads it from
#                              the private key in the keychain
#   WT_SPARKLE_KEY_FILE        a private key file (CI; `generate_keys -x`) instead of the keychain
#   WT_RELEASE_UNSIGNED=1      force the ad-hoc "unsigned test build" even with credentials present
#   WT_RELEASE_REQUIRE_NOTARIZED=1
#                              fail instead of falling back (CI's release job sets it)

set -euo pipefail

release_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
release_client="$release_root/client"
release_version_file="$release_client/Config/Version.xcconfig"
release_build_root="${WT_RELEASE_OUT:-$release_client/build/release}"
release_derived="$release_build_root/DerivedData"

say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# A banner nobody scrolls past.
loud() {
    local line="################################################################################"
    printf '\n%s\n' "$line" >&2
    local text
    for text in "$@"; do printf '#  %s\n' "$text" >&2; done
    printf '%s\n\n' "$line" >&2
}

# `xcconfig_value KEY FILE`: the value of a plain `KEY = value` line.
xcconfig_value() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\\([^[:space:]]*\\)[[:space:]]*\$/\\1/p" "$2" | tail -n 1
}

release_marketing_version() { xcconfig_value MARKETING_VERSION "$release_version_file"; }
release_build_number() { xcconfig_value CURRENT_PROJECT_VERSION "$release_version_file"; }

# GitHub Releases (D-080): the repository, and the release name "YYYY.MM.DD-NNN" -- the local date
# and that day's three-digit sequence from 001 -- used for the tag, the title and the file names.
release_repo="${WT_GITHUB_REPO:-teacurran/WireTuner2}"
# Which release the other scripts work on: `make release` writes the directory's path here.
release_pointer="$release_build_root/release-dir.txt"

# The directory of the release being worked on: WT_RELEASE_DIR, else the one `make release` built.
release_dir() {
    if [ -n "${WT_RELEASE_DIR:-}" ]; then echo "$WT_RELEASE_DIR"; return 0; fi
    [ -s "$release_pointer" ] || die "no release built yet (run make release, or set WT_RELEASE_DIR)"
    cat "$release_pointer"
}

# Every release tag that exists: this checkout's git tags and the GitHub repository's releases and
# tags (through gh, when it is installed and signed in).
release_tags() {
    git -C "$release_root" tag -l 2>/dev/null || true
    if command -v gh >/dev/null; then
        gh release list --repo "$release_repo" --limit 200 --json tagName -q '.[].tagName' 2>/dev/null || true
        gh api "repos/$release_repo/tags?per_page=100" --paginate -q '.[].name' 2>/dev/null || true
    fi
}

# The next free name for today (WT_RELEASE_DATE=YYYY.MM.DD overrides the date).
next_release_name() {
    local day="${WT_RELEASE_DATE:-$(date +%Y.%m.%d)}" highest
    [[ "$day" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || die "release date '$day' is not YYYY.MM.DD"
    highest="$(release_tags | sed -n "s/^${day//./\\.}-\([0-9]\{3\}\)\$/\1/p" | sort -n | tail -n 1)"
    printf '%s-%03d\n' "$day" "$((10#${highest:-0} + 1))"
}

# Whether a release name is already a tag here or on GitHub.
release_name_taken() { release_tags | grep -qxF "$1"; }

# `plist_value FILE KEY`: a top-level string from a plist (binary or XML), empty when absent.
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

# The git commit a release is built from, "unknown" outside a checkout.
release_commit() {
    local commit
    # Only a checkout of this tree counts: a snapshot inside another checkout is not its HEAD.
    if [ "$(git -C "$release_root" rev-parse --show-toplevel 2>/dev/null)" != "$release_root" ]; then echo unknown; return 0; fi
    commit="$(git -C "$release_root" rev-parse HEAD 2>/dev/null || true)"
    if [ -z "$commit" ]; then echo unknown; return 0; fi
    if [ -n "$(git -C "$release_root" status --porcelain 2>/dev/null)" ]; then commit="$commit-dirty"; fi
    echo "$commit"
}

# Sparkle's command-line tools (generate_keys, sign_update), from the Sparkle binary the build
# resolved; WT_SPARKLE_BIN overrides.
sparkle_bin() {
    if [ -n "${WT_SPARKLE_BIN:-}" ]; then echo "$WT_SPARKLE_BIN"; return 0; fi
    local candidate
    for candidate in "$release_derived/SourcePackages/artifacts/sparkle/Sparkle/bin" \
        "$release_client/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"; do
        if [ -x "$candidate/sign_update" ]; then echo "$candidate"; return 0; fi
    done
    candidate="$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 7 -path '*artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -n 1)"
    [ -n "$candidate" ] && echo "$candidate"
}

# Sets signing_mode (developer-id | unsigned), signing_identity and signing_team.
detect_signing() {
    signing_mode=unsigned signing_identity="-" signing_team=""
    if [ "${WT_RELEASE_UNSIGNED:-}" = 1 ]; then return 0; fi
    local identities
    identities="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/^ *[0-9]*) [0-9A-F]\{40\} "\(Developer ID Application: .*\)"$/\1/p' | sort -u)" 
    if [ -n "${WT_DEVELOPER_ID_IDENTITY:-}" ]; then
        printf '%s\n' "$identities" | grep -qxF "$WT_DEVELOPER_ID_IDENTITY" \
            || die "WT_DEVELOPER_ID_IDENTITY is not a valid code-signing identity in the keychain (security find-identity -v -p codesigning)"
        signing_identity="$WT_DEVELOPER_ID_IDENTITY"
    elif [ -n "$identities" ]; then
        [ "$(printf '%s\n' "$identities" | wc -l | tr -d ' ')" = 1 ] \
            || die "several Developer ID Application identities in the keychain; set WT_DEVELOPER_ID_IDENTITY to one"
        signing_identity="$identities"
    else
        return 0
    fi
    signing_team="${WT_TEAM_ID:-$(printf '%s' "$signing_identity" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')}"
    [ -n "$signing_team" ] || die "no team id: set WT_TEAM_ID (the identity names none)"
    signing_mode=developer-id
}

# Sets notary_args (an array for `xcrun notarytool`); empty when no credential is present.
detect_notary() {
    notary_args=()
    if [ -n "${WT_NOTARY_PROFILE:-}" ]; then
        notary_args=(--keychain-profile "$WT_NOTARY_PROFILE")
    elif [ -n "${WT_NOTARY_KEY_PATH:-}" ] || [ -n "${WT_NOTARY_KEY_ID:-}" ]; then
        [ -f "${WT_NOTARY_KEY_PATH:-}" ] || die "WT_NOTARY_KEY_PATH does not name a readable .p8 file"
        [ -n "${WT_NOTARY_KEY_ID:-}" ] || die "WT_NOTARY_KEY_ID is required with WT_NOTARY_KEY_PATH"
        notary_args=(--key "$WT_NOTARY_KEY_PATH" --key-id "$WT_NOTARY_KEY_ID")
        if [ -n "${WT_NOTARY_ISSUER:-}" ]; then notary_args+=(--issuer "$WT_NOTARY_ISSUER"); fi
    fi
}

# The Sparkle public key for the build: WT_SPARKLE_PUBLIC_KEY, else the keychain's (or the key
# file's) via generate_keys / sign_update; empty when there is none.
sparkle_public_key() {
    if [ -n "${WT_SPARKLE_PUBLIC_KEY:-}" ]; then echo "$WT_SPARKLE_PUBLIC_KEY"; return 0; fi
    local bin
    bin="$(sparkle_bin)"
    [ -n "$bin" ] || return 0
    if [ -n "${WT_SPARKLE_KEY_FILE:-}" ]; then
        return 0 # A key file carries no public half; CI sets WT_SPARKLE_PUBLIC_KEY beside it.
    fi
    local key
    key="$("$bin/generate_keys" ${WT_SPARKLE_KEY_ACCOUNT:+--account "$WT_SPARKLE_KEY_ACCOUNT"} -p 2>/dev/null)" || return 0
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    # A base64 32-byte key is 44 characters; anything else is a message, not a key.
    if [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then echo "$key"; fi
}
