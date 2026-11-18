#!/usr/bin/env bash
# The job summary of an os-update apply leg shows the role's per-host line only
# while the workflow's `summary_grep` still matches the text the role prints.
# Both live in different files, so a reword of either one silently empties the
# summary. Offline: reads files, talks to nothing.
set -uo pipefail

MAIN="ansible/collections/maestra/infra/roles/os_update/tasks/main.yml"
WF=".github/workflows/ansible-os-update.yml"
RUN=".github/workflows/ansible-run.yml"
fail=0

ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

echo "== os-update result line"

re=$(sed -n 's/^ *summary_grep: "\(.*\)"$/\1/p' "$WF")
[ -n "$re" ] || { bad "no summary_grep in $WF"; echo "$fail failure(s)"; exit 1; }

# The same extraction the summary step runs, on a log shaped like a real one
# (colour codes included), built from the role's own message text.
log=$(mktemp)
trap 'rm -f "$log"' EXIT
{
  printf '\033[0;32m    "msg": "%s host1 kernel a -> b, packages 3, rebooted yes, reboot pending False, checks ok"\033[0m\n' \
    "$(grep -o 'os-update result:' "$MAIN" | head -1)"
  printf '\033[0;32m    "msg": "host2%s"\033[0m\n' \
    "$(grep -o ': already up to date, no reboot pending — untouched\.' "$MAIN" | head -1)"
  printf '    "msg": "host1 kernel=a newest=b pending_pkgs=3"\n'
} > "$log"

got=$(grep -oE "\"msg\": \".*\"" "$log" | sed -E 's/^"msg": "//; s/"$//' | grep -E -- "$re")
[ "$(printf '%s\n' "$got" | grep -c .)" = 2 ] \
  && ok "summary_grep picks the result line and the nothing-to-do line, nothing else" \
  || bad "summary_grep /$re/ matched: $got"

grep -q 'SUMMARY_GREP: ${{ inputs.summary_grep }}' "$RUN" \
  && ok "ansible-run.yml feeds summary_grep to the summary step" \
  || bad "ansible-run.yml does not pass summary_grep to the summary step"

# The line is printed in `always`, before the job is failed: a failed host
# reports FAILED instead of vanishing.
awk '/^    - name: Result$/{r=NR} /^    - name: Fail the job$/&&r&&!f{f=NR} END{exit !(r&&f&&r<f)}' "$MAIN" \
  && ok "Result is printed before Fail the job" \
  || bad "Result task missing or after Fail the job in $MAIN"

# A consumer may replace reboot.yml (kube: reboot-deckhouse), so the line may
# read only facts main.yml sets itself; and whoever drives the sweep greps these
# two tokens.
res=$(awk '/^    - name: Result$/{r=1} /^    - name: Fail the job$/{r=0} r' "$MAIN")
if printf '%s' "$res" | grep -qE 'os_update_(booted_kernel|newest_kernel_post)'; then
  bad "Result reads a fact only the role's own reboot.yml sets"
else
  ok "Result does not depend on which reboot.yml ran"
fi
printf '%s' "$res" | grep -q 'reboot pending ' && printf '%s' "$res" | grep -q "'FAILED'" \
  && ok "Result keeps the reboot pending and FAILED tokens" \
  || bad "Result lost the 'reboot pending' or 'FAILED' token"

echo "$fail failure(s)"
[ "$fail" = 0 ]
