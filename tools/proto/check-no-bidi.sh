#!/usr/bin/env bash
# The no-bidi rule (docs/spec/api-conventions.adoc, "Services and RPC shape"; decisions.adoc
# D-044): no RPC may stream in both directions, so every call works through a Connect or
# gRPC-Web gateway and an HTTP/1.1 load balancer.  buf's built-in lint has no such rule and a
# custom lint plugin needs a Go toolchain the developer machines do not have, so this script is
# the rule: every .proto file is normalised with `buf format` (which puts each `rpc` on one
# line), comments are stripped, and any `rpc X(stream A) returns (stream B)` fails the check.
#
#     tools/proto/check-no-bidi.sh              # checks proto/
#     tools/proto/check-no-bidi.sh DIR|FILE ... # checks these instead (the self-test uses it)
#
# Exit 0 when no bidirectional RPC exists, 1 when one does (each is printed as file:line),
# 2 on a usage or tooling error.  Wired into `make proto-lint` and the proto workflow.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"

if ! command -v buf >/dev/null 2>&1; then
    echo "check-no-bidi: buf is not installed" >&2
    exit 2
fi

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
    targets=("$root/proto")
fi

files=()
for target in "${targets[@]}"; do
    if [ -d "$target" ]; then
        while IFS= read -r file; do
            files+=("$file")
        done < <(find "$target" -type f -name '*.proto' | sort)
    elif [ -f "$target" ]; then
        files+=("$target")
    else
        echo "check-no-bidi: no such file or directory: $target" >&2
        exit 2
    fi
done

if [ ${#files[@]} -eq 0 ]; then
    echo "check-no-bidi: no .proto files under ${targets[*]}" >&2
    exit 2
fi

# `rpc Name(stream Req) returns (stream Resp)`, whitespace-tolerant, after `buf format` has put
# the whole declaration on one line and `sed` has removed line comments.
pattern='rpc[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\([[:space:]]*stream[[:space:]]+[A-Za-z0-9_.]+[[:space:]]*\)[[:space:]]*returns[[:space:]]*\([[:space:]]*stream[[:space:]]'

status=0
for file in "${files[@]}"; do
    # buf format prints the formatted file; a syntax error is a tooling failure, not a pass.
    if ! formatted="$(buf format "$file" 2>&1)"; then
        echo "check-no-bidi: buf format failed on $file:" >&2
        echo "$formatted" >&2
        exit 2
    fi
    hits="$(printf '%s\n' "$formatted" | sed -e 's://.*$::' | grep -En "$pattern" || true)"
    if [ -n "$hits" ]; then
        status=1
        while IFS= read -r hit; do
            echo "$file:$hit: bidirectional streaming RPC; use a server-streaming subscription plus unary commands (api-conventions.adoc)" >&2
        done <<< "$hits"
    fi
done

if [ $status -eq 0 ]; then
    echo "check-no-bidi: ${#files[@]} file(s), no bidirectional RPC"
fi
exit $status
