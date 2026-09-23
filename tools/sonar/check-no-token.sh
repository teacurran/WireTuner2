#!/usr/bin/env bash
# Fails if any file in the repository contains a SonarQube token (docs/spec/testing.adoc,
# "Coverage and SonarQube": the token is never written into the repository).  Token shapes:
# user tokens `squ_`, project analysis tokens `sqp_`, global analysis tokens `sqa_`, each followed
# by 40 lowercase hex digits.
#
#     tools/sonar/check-no-token.sh              # every tracked and untracked-but-not-ignored file
#     tools/sonar/check-no-token.sh PATH ...     # these files/directories instead (the self-test)
#
# Only the file and line number of a hit are printed, never the matching text, so the check
# cannot itself leak a token into a CI log.  Exit 0 when clean, 1 on a hit, 2 on a usage error.
# Wired into both workflows' sonar jobs (.github/workflows/server.yml, client.yml).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
pattern='sq[upa]_[0-9a-f]{40}'

files=()
if [ $# -eq 0 ]; then
    if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        while IFS= read -r -d '' file; do
            [ -f "$root/$file" ] && files+=("$root/$file")
        done < <(git -C "$root" ls-files -z --cached --others --exclude-standard)
    else
        while IFS= read -r -d '' file; do
            files+=("$file")
        done < <(find "$root" -type f -not -path '*/.git/*' -print0)
    fi
else
    for target in "$@"; do
        if [ -d "$target" ]; then
            while IFS= read -r -d '' file; do
                files+=("$file")
            done < <(find "$target" -type f -print0)
        elif [ -f "$target" ]; then
            files+=("$target")
        else
            echo "check-no-token: no such file or directory: $target" >&2
            exit 2
        fi
    done
fi

hits=0
if [ ${#files[@]} -gt 0 ]; then
    # -I skips binary files; -o with cut keeps only "file:line", never the token itself.
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        echo "${hit#"$root"/}: looks like a SonarQube token; revoke it on the server and remove it" >&2
        hits=$((hits + 1))
    done < <(printf '%s\0' "${files[@]}" | xargs -0 grep -I -n -o -E "$pattern" 2>/dev/null | cut -d: -f1,2 | sort -u || true)
fi

if [ "$hits" -gt 0 ]; then
    exit 1
fi
echo "check-no-token: ${#files[@]} file(s), no SonarQube token"
