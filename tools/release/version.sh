#!/usr/bin/env bash
# The version and build number in client/Config/Version.xcconfig (docs/spec/releasing.adoc).
#
#     tools/release/version.sh show                 # 0.1.0 (1)
#     tools/release/version.sh bump-build           # build + 1                (make bump-build)
#     tools/release/version.sh bump-version 0.2.0   # a new marketing version  (make bump-version VERSION=0.2.0)
#     tools/release/version.sh bump-version         # the next patch version
#
# The build number only goes up, across marketing versions too: Sparkle orders updates by it.
source "$(dirname "$0")/common.sh"

file="${WT_VERSION_FILE:-$release_version_file}"
marketing="$(xcconfig_value MARKETING_VERSION "$file")"
build="$(xcconfig_value CURRENT_PROJECT_VERSION "$file")"
[[ "$marketing" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$file: MARKETING_VERSION '$marketing' is not X.Y.Z"
[[ "$build" =~ ^[1-9][0-9]*$ ]] || die "$file: CURRENT_PROJECT_VERSION '$build' is not a positive integer"

set_value() {
    local key="$1" value="$2"
    sed -i '' "s/^\\([[:space:]]*$key[[:space:]]*=[[:space:]]*\\).*\$/\\1$value/" "$file"
    [ "$(xcconfig_value "$key" "$file")" = "$value" ] || die "could not write $key to $file"
}

# 1 when X.Y.Z $1 is greater than $2.
version_greater() {
    local IFS=.
    local -a a=($1) b=($2)
    local i
    for i in 0 1 2; do
        if ((10#${a[i]} > 10#${b[i]})); then return 0; fi
        if ((10#${a[i]} < 10#${b[i]})); then return 1; fi
    done
    return 1
}

case "${1:-show}" in
show)
    echo "$marketing ($build)"
    ;;
bump-build)
    set_value CURRENT_PROJECT_VERSION "$((build + 1))"
    echo "$marketing ($((build + 1)))"
    ;;
bump-version)
    next="${2:-}"
    if [ -z "$next" ]; then
        IFS=. read -r major minor patch <<<"$marketing"
        next="$major.$minor.$((patch + 1))"
    fi
    [[ "$next" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$next' is not X.Y.Z"
    version_greater "$next" "$marketing" || die "version $next is not greater than $marketing"
    set_value MARKETING_VERSION "$next"
    set_value CURRENT_PROJECT_VERSION "$((build + 1))"
    echo "$next ($((build + 1)))"
    ;;
*)
    die "usage: $0 show | bump-build | bump-version [X.Y.Z]"
    ;;
esac
