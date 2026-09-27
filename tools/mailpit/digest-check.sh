#!/bin/bash
# COLLAB-034: the comment digest asserted against the compose stack's Mailpit.
#
#   tools/mailpit/digest-check.sh
#
# Starts the `mailpit` service of docker-compose.yml under its own compose project on two free host
# ports (so a running development stack and its 8025/1025 are left alone), runs the server's
# CommentDigestMailpitTest with the real mailer pointed at it (-Dwt.mailpit.api / -Dwt.mailpit.smtp),
# and removes the service and its volume afterwards, whatever the result.  Needs Docker and JDK 25
# (JAVA_HOME).  WT_MAILPIT_PROJECT overrides the compose project name.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
project="${WT_MAILPIT_PROJECT:-wt-digest-check-$$}"
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
ui="$(free_port)"
smtp="$(free_port)"
override="$(mktemp -t wt-mailpit-override)"
cat > "$override" <<YAML
services:
  mailpit:
    ports: !override
      - "127.0.0.1:${ui}:8025"
      - "127.0.0.1:${smtp}:1025"
YAML
compose=(docker compose -p "$project" -f "$root/docker-compose.yml" -f "$override")
cleanup() {
    "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    rm -f "$override"
}
trap cleanup EXIT

"${compose[@]}" up -d mailpit
for _ in $(seq 1 60); do
    curl -sf "http://127.0.0.1:${ui}/api/v1/info" >/dev/null && break
    sleep 1
done
curl -sf "http://127.0.0.1:${ui}/api/v1/info" >/dev/null || { echo "mailpit did not answer on :${ui}" >&2; exit 1; }
echo "mailpit (project ${project}): UI :${ui}, SMTP :${smtp}"

cd "$root/server"
./mvnw -q -pl api -am test -Dtest=CommentDigestMailpitTest -Dsurefire.failIfNoSpecifiedTests=false -Djacoco.skip=true \
    -Dwt.mailpit.api="http://127.0.0.1:${ui}" -Dwt.mailpit.smtp="${smtp}"
report="$root/server/api/target/surefire-reports/com.villagecompute.wiretuner.api.comments.CommentDigestMailpitTest.txt"
cat "$report"
grep -q "Tests run: [1-9][0-9]*, Failures: 0, Errors: 0, Skipped: 0" "$report"
