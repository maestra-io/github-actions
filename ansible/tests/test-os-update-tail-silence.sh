#!/usr/bin/env bash
# The post-run tail silence (tail_silence.yml, issues-maestra#1104).
#   1. wiring: posted only on APPLY's success path, before the unsilence; never
#      by binary-update or undrain-only.
#   2. the REAL task files against a fake Alertmanager: the tail carries the same
#      matcher sets, createdBy os-update-tail, endsAt = now + N min in UTC, and
#      goes up BEFORE the maintenance silences are expired.
#   3. a tail never trips the one-at-a-time guard; a maintenance silence does.
# Needs ansible-playbook (collection-lint installs it). Offline otherwise.
set -uo pipefail
cd "$(dirname "$0")/../.."

MAIN="ansible/collections/maestra/infra/roles/os_update/tasks/main.yml"
T="ansible/tests/os-update-tail"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

echo "== wiring"
code=$(sed 's/#.*$//' "$MAIN")
apply_always=$(echo "$code" | awk '/^- name: APPLY$/{f=1} /^- name: BINARY-UPDATE/{f=0} f' | awk '/^  always:/{f=1} f')
tail_line=$(echo "$apply_always" | grep -n "tail_silence.yml" | head -1 | cut -d: -f1)
unsil_line=$(echo "$apply_always" | grep -n "unsilence.yml" | head -1 | cut -d: -f1)
[ -n "$tail_line" ] && [ -n "$unsil_line" ] && [ "$tail_line" -lt "$unsil_line" ] \
  && ok "APPLY's always posts the tail before the unsilence" \
  || bad "APPLY's always does not post the tail before the unsilence"
echo "$apply_always" | grep -B12 "tail_silence.yml" | grep -q "not (os_update_failed" \
  && echo "$apply_always" | grep -B12 "tail_silence.yml" | grep -q "not (os_update_undrain_failed" \
  && ok "the tail is gated on a successful run" \
  || bad "the tail is not gated on os_update_failed / os_update_undrain_failed"
[ "$(echo "$code" | grep -c "tail_silence.yml")" -eq 2 ] \
  && ok "exactly two tails: APPLY's always and the undrain-only hatch (binary-update posts none)" \
  || bad "tail_silence.yml included $(echo "$code" | grep -c "tail_silence.yml") times, want 2 (APPLY always + UNDRAIN-ONLY)"
hatch=$(echo "$code" | awk '/^- name: UNDRAIN-ONLY/{f=1} /end_host/{if(f){print; f=0}} f')
h_tail=$(echo "$hatch" | grep -n "tail_silence.yml" | head -1 | cut -d: -f1)
h_unsil=$(echo "$hatch" | grep -n "unsilence.yml" | head -1 | cut -d: -f1)
[ -n "$h_tail" ] && [ -n "$h_unsil" ] && [ "$h_tail" -lt "$h_unsil" ] \
  && ok "the undrain-only hatch posts the tail before its unsilence" \
  || bad "the undrain-only hatch does not post the tail before its unsilence"

echo "== fake Alertmanager"
tmp=$(mktemp -d); trap 'kill "$am_pid" 2>/dev/null; rm -rf "$tmp"' EXIT
python3 -I "$T/fake_am.py" "$tmp/log.jsonl" > "$tmp/port" &
am_pid=$!
for _ in $(seq 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
port=$(cat "$tmp/port")
[ -n "$port" ] || { bad "fake Alertmanager did not start"; exit 1; }

before=$(date +%s)
# A non-UTC controller is the trap silence.yml documents; prove utc=true holds.
TZ=America/Los_Angeles ANSIBLE_LOCALHOST_WARNING=false ansible-playbook \
  -i "us-test-worker02," -c local -e "am=http://127.0.0.1:${port}" \
  -e 'ansible_python_interpreter={{ ansible_playbook_python }}' \
  "$T/playbook.yml" > "$tmp/play.log" 2>&1 \
  && ok "playbook ran (guard truth table asserted inside it)" \
  || { bad "playbook failed"; cat "$tmp/play.log"; }
after=$(date +%s)

python3 -I - "$tmp/log.jsonl" "$before" "$after" "$T/playbook.yml" <<'PY' || fail=$((fail + 1))
import json, sys
from datetime import datetime, timezone
log, before, after = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
reqs = [json.loads(l) for l in open(log)]
posts = [r for r in reqs if r["method"] == "POST"]
dels = [r for r in reqs if r["method"] == "DELETE"]
errs = []
def ts(s): return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.000Z").replace(tzinfo=timezone.utc).timestamp()
want_sets = [
    [{"name": "instance", "value": "us-test-worker02.*", "isRegex": True}],
    [{"name": "namespace", "value": "^(kafka-common)$", "isRegex": True},
     {"name": "cluster", "value": "us-test-cluster", "isRegex": False}],
]
if [p["body"]["matchers"] for p in posts] != want_sets:
    errs.append("tail matchers != os_update_silence_sets: %r" % [p["body"]["matchers"] for p in posts])
for p in posts:
    b = p["body"]
    if b["createdBy"] != "os-update-tail":
        errs.append("createdBy %r" % b["createdBy"])
    if not b["comment"].startswith("OS update tail issues-maestra#1104 contour=us_test_lw host=us-test-worker02 run=https://example.invalid/run/1 "):
        errs.append("comment %r" % b["comment"])
    s, e = ts(b["startsAt"]), ts(b["endsAt"])
    if not (before - 1 <= s <= after + 1):
        errs.append("startsAt %s is not now in UTC" % b["startsAt"])
    if abs((e - s) - 15 * 60) > 1:
        errs.append("endsAt - startsAt = %ss, want 900" % (e - s))
if [d["path"] for d in dels] != ["/run/api/v2/silence/orig-1", "/run/api/v2/silence/orig-2"]:
    errs.append("expired %r, want orig-1, orig-2" % [d["path"] for d in dels])
if reqs and [r["method"] for r in reqs] != ["POST"] * len(posts) + ["DELETE"] * len(dels):
    errs.append("order %r: the tail must go up before the originals are expired" % [r["method"] for r in reqs])
for e in errs: print("  FAIL", e)
if not errs: print("  ok   tail body: same sets, createdBy os-update-tail, UTC endsAt = now + 15m, posted before the expiry")
sys.exit(1 if errs else 0)
PY

echo "== the guard regex does not select the tail"
python3 -I -c 'import re,sys; sys.exit(0 if re.search("^gha-os-update","os-update-tail") is None else 1)' \
  && ok "'^gha-os-update' does not match 'os-update-tail'" \
  || bad "'^gha-os-update' matches the tail's createdBy"

echo
if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "$fail failure(s)"; fi
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
