#!/usr/bin/env bash
# Creates (or converges) the two SonarQube projects and their quality gates through the Web API
# (docs/spec/testing.adoc, "Coverage and SonarQube"; decisions.adoc D-066).  Idempotent: every
# object is read first and written only when missing or different, so a second run makes no
# changes.
#
#     tools/sonar/configure-gates.sh             # apply against $SONAR_HOST_URL
#     tools/sonar/configure-gates.sh --dry-run   # print the calls a run on an empty server makes
#
#   project           gate              conditions (metric < 95 fails)
#   wiretuner-server  wiretuner-server  new_line_coverage, line_coverage,
#                                       new_branch_coverage, branch_coverage
#   wiretuner-client  wiretuner-client  new_line_coverage, line_coverage
#
# The client gate has no condition metric: Swift's coverage mapping emits no branch records, so
# Sonar would never have a branch measure for it.  The client's branch gate is the llvm-cov
# region gate in CI (tools/coverage/regions-gate.swift).  Conditions other than these are left
# alone (and listed), so hand-added conditions survive a re-run.
#
# Token: $SONAR_TOKEN, else ~/.sonar-token; it needs the "Administer Quality Gates" and "Create
# Projects" permissions.  It is sent in a curl config on stdin, never on a command line or in the
# output.  Host: $SONAR_HOST_URL, default https://sonar.villagecompute.com.
# Exit 0 on success, 1 on an API error, 2 on a usage error or missing token.
set -euo pipefail

host="${SONAR_HOST_URL:-https://sonar.villagecompute.com}"
host="${host%/}"
threshold=95
dry_run=false

for argument in "$@"; do
    case "$argument" in
        --dry-run) dry_run=true ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "configure-gates: unknown argument: $argument" >&2; exit 2 ;;
    esac
done

token=""
if [ "$dry_run" = false ]; then
    token="${SONAR_TOKEN:-}"
    if [ -z "$token" ] && [ -r "$HOME/.sonar-token" ]; then
        token="$(tr -d '[:space:]' < "$HOME/.sonar-token")"
    fi
    if [ -z "$token" ]; then
        echo "configure-gates: no token: set SONAR_TOKEN or write it to ~/.sonar-token" >&2
        exit 2
    fi
fi
command -v jq >/dev/null 2>&1 || { echo "configure-gates: jq is required" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# api METHOD PATH [key=value ...]: prints the response body; fails on a non-2xx status.  In a dry
# run a GET answers "not found" (an empty server) and a POST is printed instead of sent.
api() {
    local method="$1" path="$2"
    shift 2
    if [ "$dry_run" = true ]; then
        if [ "$method" = POST ]; then
            echo "POST $path $*"
        fi
        return 3
    fi
    local args=(-sS -o "$work/body" -w '%{http_code}' -X "$method" -K -)
    local pair
    for pair in "$@"; do
        if [ "$method" = GET ]; then
            args+=(-G --data-urlencode "$pair")
        else
            args+=(--data-urlencode "$pair")
        fi
    done
    local status
    status="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl "${args[@]}" "$host/$path")" || {
        echo "configure-gates: $method $path: request failed" >&2
        exit 1
    }
    if [ "$status" = 404 ]; then
        return 3
    fi
    if [ "${status:0:1}" != 2 ]; then
        echo "configure-gates: $method $path: HTTP $status: $(cat "$work/body")" >&2
        exit 1
    fi
    [ "$method" = GET ] && cat "$work/body"
    [ "$method" = POST ] && echo "POST $path $* -> $status"
    return 0
}

# get PATH [key=value ...]: api GET that tells "not found" (status 3, empty output) from a real
# failure; a failure inside $(...) exits only the subshell, so it is re-raised here.
get() {
    local rc=0
    api GET "$@" || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
        exit 1
    fi
    return "$rc"
}

ensure_project() {
    local key="$1" found rc=0
    found="$(get api/projects/search projects="$key")" || rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || exit 1
    if [ "$rc" -eq 0 ] &&
        [ "$(jq --arg key "$key" '[.components[] | select(.key == $key)] | length' <<< "$found")" -gt 0 ]; then
        echo "project $key: exists"
    else
        api POST api/projects/create project="$key" name="$key" mainBranch=main || true
    fi
}

ensure_gate() {
    local gate="$1"
    shift
    local shown="" rc=0
    shown="$(get api/qualitygates/show name="$gate")" || rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || exit 1
    if [ "$rc" -eq 0 ]; then
        echo "gate $gate: exists"
    else
        api POST api/qualitygates/create name="$gate" || true
        shown='{"conditions":[]}'
    fi
    local metric id op error
    for metric in "$@"; do
        id="$(jq -r --arg m "$metric" '[.conditions[]? | select(.metric == $m)][0].id // empty' <<< "$shown")"
        if [ -z "$id" ]; then
            api POST api/qualitygates/create_condition gateName="$gate" metric="$metric" op=LT error="$threshold" || true
            continue
        fi
        op="$(jq -r --arg m "$metric" '[.conditions[] | select(.metric == $m)][0].op' <<< "$shown")"
        error="$(jq -r --arg m "$metric" '[.conditions[] | select(.metric == $m)][0].error' <<< "$shown")"
        if [ "$op" = LT ] && [ "$error" = "$threshold" ]; then
            echo "gate $gate: $metric < $threshold already"
        else
            api POST api/qualitygates/update_condition id="$id" metric="$metric" op=LT error="$threshold" || true
        fi
    done
    local others
    others="$(jq -r '[.conditions[]? | select(.metric as $m | $ARGS.positional | index($m) | not) | .metric] | join(", ")' --args "$@" <<< "$shown")"
    if [ -n "$others" ]; then
        echo "gate $gate: leaving other conditions alone: $others"
    fi
}

select_gate() {
    local gate="$1" project="$2" current rc=0
    current="$(get api/qualitygates/get_by_project project="$project")" || rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || exit 1
    if [ "$rc" -eq 0 ] &&
        [ "$(jq -r '.qualityGate.name' <<< "$current")" = "$gate" ]; then
        echo "project $project: uses gate $gate already"
    else
        api POST api/qualitygates/select gateName="$gate" projectKey="$project" || true
    fi
}

[ "$dry_run" = true ] && echo "dry run against $host (no requests are sent):"

ensure_project wiretuner-server
ensure_project wiretuner-client
ensure_gate wiretuner-server new_line_coverage line_coverage new_branch_coverage branch_coverage
ensure_gate wiretuner-client new_line_coverage line_coverage
select_gate wiretuner-server wiretuner-server
select_gate wiretuner-client wiretuner-client

echo "configure-gates: done"
