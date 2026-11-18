#!/usr/bin/env bash
# Tests the spot interruption scripts against stubbed aws and gh commands.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
stubs=$(mktemp -d)
trap 'rm -rf "$stubs"' EXIT
failures=0

cat > "$stubs/aws" <<'STUB'
#!/usr/bin/env bash
[ "$STUB_AWS_EXIT" = "0" ] || exit "$STUB_AWS_EXIT"
echo "$STUB_STATE_REASON"
STUB

cat > "$stubs/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "run list"*) echo "$STUB_LATEST_RUN" ;;
    "run rerun"*) echo "$*" >> "$STUB_RERUN_LOG" ;;
    *"/jobs"*) printf '%s\n' 101 102 ;;
    *"check-runs/102/annotations"*) [ -z "$STUB_ANNOTATION" ] || echo "$STUB_ANNOTATION" ;;
    *"/annotations"*) ;;
    *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB
cat > "$stubs/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"api/token"*)
        [ "$STUB_TOKEN_OK" = "1" ] || exit 22
        echo token-value
        ;;
    *"X-aws-ec2-metadata-token: token-value"*"spot/instance-action"*)
        echo poll >> "$STUB_WATCH_LOG"
        [ "$(grep -c '^poll' "$STUB_WATCH_LOG")" -ge "$STUB_NOTICE_ON_POLL" ] || exit 22
        ;;
    *) exit 22 ;;
esac
STUB

cat > "$stubs/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "ps -q") echo container-1 ;;
    *) echo "docker $*" >> "$STUB_WATCH_LOG" ;;
esac
STUB

cat > "$stubs/pkill" <<'STUB'
#!/usr/bin/env bash
echo "pkill $*" >> "$STUB_WATCH_LOG"
STUB

cat > "$stubs/sleep" <<'STUB'
#!/usr/bin/env bash
echo sleep >> "$STUB_WATCH_LOG"
if [ "$(grep -c '^sleep' "$STUB_WATCH_LOG")" -ge 3 ]; then kill "$PPID"; fi
STUB

chmod +x "$stubs/aws" "$stubs/gh" "$stubs/curl" "$stubs/docker" "$stubs/pkill" "$stubs/sleep"

export PATH="$stubs:$PATH"
export INSTANCE_ID=i-test REPOSITORY=owner/repo RUN_ID=500 WORKFLOW_ID=9 HEAD_BRANCH=main
export STUB_RERUN_LOG="$stubs/reruns"

check() {
    local name=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "ok - $name"
    else
        echo "not ok - $name (expected '$expected', got '$actual')"
        failures=$((failures + 1))
    fi
}

report() {
    STUB_STATE_REASON=$1 STUB_AWS_EXIT=$2 bash "$root/stop-self-hosted/report-spot-interruption.sh"
}

retry_count() {
    rm -f "$STUB_RERUN_LOG"
    RUN_CONCLUSION=$1 RUN_ATTEMPT=$2 STUB_LATEST_RUN=$3 STUB_ANNOTATION=$4 \
        bash "$root/retry-spot-interruption/retry.sh" > /dev/null
    if [ -f "$STUB_RERUN_LOG" ]; then wc -l < "$STUB_RERUN_LOG"; else echo 0; fi
}

title="Spot instance reclaimed"

check "spot termination is annotated" \
    "::error title=$title::AWS reclaimed spot instance i-test while it was running this workflow." \
    "$(report Server.SpotInstanceTermination 0)"
check "other state reasons are not annotated" "" "$(report Client.UserInitiatedShutdown 0)"
check "running instances are not annotated" "" "$(report None 0)"
check "lookup failure warns without failing" \
    "::warning::Could not determine why instance i-test stopped." "$(report "" 1)"

check "reclaimed latest first attempt re-runs" 1 "$(retry_count failure 1 500 "$title")"
check "unrelated failure does not re-run" 0 "$(retry_count failure 1 500 "")"
check "superseded run does not re-run" 0 "$(retry_count failure 1 501 "$title")"
check "second attempt does not re-run" 0 "$(retry_count failure 2 500 "$title")"
check "successful run does not re-run" 0 "$(retry_count success 1 500 "$title")"

export STUB_WATCH_LOG="$stubs/watch-log"
marker="$stubs/notice"

watch() {
    rm -f "$STUB_WATCH_LOG" "$marker"
    touch "$STUB_WATCH_LOG"
    STUB_NOTICE_ON_POLL=$1 STUB_TOKEN_OK=$2 \
        bash "$root/container-build/spot-interruption-watcher.sh" "$marker" > /dev/null 2>&1 || true
}

marker_state() {
    if [ -f "$marker" ]; then echo present; else echo absent; fi
}

watch 2 1
check "notice writes the marker" present "$(marker_state)"
check "notice is seen on the second poll" 2 "$(grep -c '^poll' "$STUB_WATCH_LOG" || true)"
check "notice kills running containers" 1 "$(grep -c '^docker kill container-1$' "$STUB_WATCH_LOG" || true)"
check "notice stops the buildx client" 1 "$(grep -c '^pkill -f buildx build$' "$STUB_WATCH_LOG" || true)"

watch 999 1
check "no notice leaves no marker" absent "$(marker_state)"
check "no notice stops nothing" 0 "$(grep -cE '^(docker|pkill) ' "$STUB_WATCH_LOG" || true)"

watch 1 0
check "missing token leaves no marker" absent "$(marker_state)"
check "missing token stops nothing" 0 "$(grep -cE '^(docker|pkill) ' "$STUB_WATCH_LOG" || true)"

check "build annotation uses the title the retry matches" 1 \
    "$(grep -c "::error title=$title::" "$root/container-build/action.yml" || true)"

exit "$failures"
