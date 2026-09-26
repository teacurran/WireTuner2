#!/usr/bin/env bash
# Tests for tools/sonar: configure-gates.sh against a stateful stub of the SonarQube Web API
# (stub_sonar.py), and check-no-token.sh against generated fixtures.  Nothing here talks to the
# real server.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tools="$here/.."
work="$(mktemp -d)"
stub_pid=""
cleanup() {
    if [ -n "$stub_pid" ]; then kill "$stub_pid" 2>/dev/null; wait "$stub_pid" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# A token-shaped value built at runtime, so no file in the repository ever holds one.
hex40="$(printf '0123456789abcdef%.0s' 1 2 3 | cut -c1-40)"
token="squ_$hex40"

# --- configure-gates.sh ------------------------------------------------------------------------
python3 "$here/stub_sonar.py" "$work/port" "$work/requests.log" "$token" &
stub_pid=$!
for _ in $(seq 50); do
    [ -s "$work/port" ] && break
    sleep 0.1
done
[ -s "$work/port" ] || fail "stub server did not start"
export SONAR_HOST_URL="http://127.0.0.1:$(cat "$work/port")"
state() { curl -sS -H "Authorization: Bearer $token" "$SONAR_HOST_URL/test/state"; }

# Dry run: prints every write an empty server needs and sends nothing, token or not.
env -u SONAR_TOKEN HOME="$work/nohome" "$tools/configure-gates.sh" --dry-run > "$work/dry.out"
test "$(grep -c '^POST ' "$work/dry.out")" -eq 12 || fail "dry run should print 12 writes"
grep -q '^POST api/qualitygates/create_condition gateName=wiretuner-server metric=branch_coverage op=LT error=95$' "$work/dry.out" || fail "dry run lacks the server branch condition"
if grep -q 'gateName=wiretuner-client metric=.*branch' "$work/dry.out"; then fail "client gate must have no branch condition"; fi
[ ! -e "$work/requests.log" ] || fail "dry run sent requests"

# No token anywhere: exit 2 before any request.
set +e
env -u SONAR_TOKEN HOME="$work/nohome" "$tools/configure-gates.sh" > /dev/null 2> "$work/err"
status=$?
set -e
test "$status" -eq 2 || fail "missing token should exit 2, got $status"
grep -q 'no token' "$work/err" || fail "missing token message"
[ ! -e "$work/requests.log" ] || fail "a run without a token sent requests"

# A wrong token: the 401 on the first read is an error, not "not found", and nothing is created.
set +e
SONAR_TOKEN=squ_wrong "$tools/configure-gates.sh" > "$work/out" 2> "$work/err"
status=$?
set -e
test "$status" -eq 1 || fail "401 should exit 1, got $status"
grep -q 'HTTP 401' "$work/err" || fail "401 message"
if grep -q '^POST' "$work/requests.log"; then fail "a 401 read must not be followed by writes"; fi
: > "$work/requests.log"

# First run, token from ~/.sonar-token: creates both projects, both gates, six conditions, two
# selections.
mkdir -p "$work/home"
printf '%s\n' "$token" > "$work/home/.sonar-token"
env -u SONAR_TOKEN HOME="$work/home" "$tools/configure-gates.sh" > "$work/run1.out"
test "$(grep -c '^POST ' "$work/requests.log")" -eq 12 || fail "first run should make 12 writes"
state | jq -e '
    (.projects | keys) == ["WireTuner", "WireTuner-Client"] and
    ([.gates["wiretuner-server"][] | .metric] | sort) == ["branch_coverage", "line_coverage", "new_branch_coverage", "new_line_coverage"] and
    ([.gates["wiretuner-client"][] | .metric] | sort) == ["line_coverage", "new_line_coverage"] and
    ([.gates[][] | select(.op != "LT" or .error != "95")] | length) == 0 and
    .selected == {"WireTuner": "wiretuner-server", "WireTuner-Client": "wiretuner-client"}
' > /dev/null || fail "unexpected server state after the first run: $(state)"
if grep -q "$hex40" "$work/run1.out" "$work/requests.log"; then fail "the token leaked into output or request parameters"; fi
: > "$work/requests.log"

# Second run, token from SONAR_TOKEN: idempotent, reads only.
SONAR_TOKEN="$token" HOME="$work/nohome" "$tools/configure-gates.sh" > "$work/run2.out"
if grep -q '^POST' "$work/requests.log"; then fail "second run should make no writes: $(grep '^POST' "$work/requests.log")"; fi
grep -q 'wiretuner-server: branch_coverage < 95 already' "$work/run2.out" || fail "second run output"
: > "$work/requests.log"

# Drift: a loosened condition is put back, a hand-added one is left alone.
curl -sS -X POST -H "Authorization: Bearer $token" "$SONAR_HOST_URL/test/drift" > /dev/null
: > "$work/requests.log"
SONAR_TOKEN="$token" "$tools/configure-gates.sh" > "$work/run3.out"
test "$(grep -c '^POST ' "$work/requests.log")" -eq 1 || fail "drift run should make exactly one write"
grep -q '^POST /api/qualitygates/update_condition error=95&id=.*&metric=branch_coverage&op=LT$' "$work/requests.log" || fail "drift not repaired: $(cat "$work/requests.log")"
grep -q 'leaving other conditions alone: new_violations' "$work/run3.out" || fail "extra condition not reported"
state | jq -e '[.gates["wiretuner-server"][] | select(.metric == "new_violations")] | length == 1' > /dev/null || fail "extra condition removed"

echo "configure-gates: stub test passed"

# --- check-no-token.sh -------------------------------------------------------------------------
fixture="$work/fixture"
mkdir -p "$fixture/clean" "$fixture/dirty"
printf 'sonar.host.url=https://sonar.villagecompute.com\nSONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}\nsqu_tooshort\nsqu_%s\n' "$(printf %s "$hex40" | tr a-f A-F)" > "$fixture/clean/ok.yml"
"$tools/check-no-token.sh" "$fixture/clean" > /dev/null || fail "clean fixture flagged"

for prefix in squ sqp sqa; do
    printf 'first line\nexport SONAR_TOKEN=%s_%s\n' "$prefix" "$hex40" > "$fixture/dirty/$prefix.env"
done
set +e
"$tools/check-no-token.sh" "$fixture/dirty" > "$work/out" 2> "$work/err"
status=$?
set -e
test "$status" -eq 1 || fail "dirty fixture should exit 1, got $status"
test "$(grep -c 'looks like a SonarQube token' "$work/err")" -eq 3 || fail "expected three hits: $(cat "$work/err")"
grep -q 'sqp.env:2:' "$work/err" || fail "hit should name file and line"
if grep -q "$hex40" "$work/err" "$work/out"; then fail "check-no-token printed the token"; fi

set +e
"$tools/check-no-token.sh" "$work/does-not-exist" > /dev/null 2>&1
status=$?
set -e
test "$status" -eq 2 || fail "missing path should exit 2, got $status"

echo "check-no-token: fixture test passed"
