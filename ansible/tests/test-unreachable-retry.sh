#!/usr/bin/env bash
# Runs `nothing_ran` from the Execute Ansible step of ansible-run.yml (the block
# between its >>>/<<< markers, extracted, not copied) against play logs, and
# checks it allows the one rerun only when no task past fact gathering started.
# Offline: reads files, talks to nothing.
set -uo pipefail

WF=".github/workflows/ansible-run.yml"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed -n '/# >>> unreachable-retry/,/# <<< unreachable-retry/p' "$WF" | sed 's/^          //' > "$T/block.sh"
[ -s "$T/block.sh" ] || { echo "FAIL block markers not found in $WF"; exit 1; }
# shellcheck source=/dev/null
. "$T/block.sh"

E=$(printf '\033')
GF='TASK [Gathering Facts] *********************************************************'
UNR='fatal: [h1]: UNREACHABLE! => {"changed": false, "msg": "Task failed: Connection timed out.", "unreachable": true}'
# play <events…> -- <recap rows…>
play() {
  printf 'PLAY [x] ***********************************************************************\n'
  while [ "$1" != -- ]; do printf '%s\n' "$1"; shift; done; shift
  printf 'PLAY RECAP *********************************************************************\n'
  printf '%s\n' "$@"
}
row() { printf '%s : ok=%s    changed=%s    unreachable=%s    failed=%s    skipped=0    rescued=%s    ignored=0' "$@"; }

# asbo 44544069208 attempt 1, colours as ANSIBLE_FORCE_COLOR prints them
play "$GF" "${E}[0;31m${UNR}${E}[0m" -- \
  "${E}[0;31meu-omega-aws-asbo-01${E}[0m       : ok=0    changed=0    ${E}[1;31munreachable=1   ${E}[0m failed=0    skipped=0    rescued=0    ignored=0   " > "$T/asbo"
nothing_ran "$T/asbo" && ok "unreachable at Gathering Facts, single host: rerun" || bad "asbo log must allow the rerun"

play "$GF" "$UNR" "$UNR" -- "$(row h1 0 0 1 0 0)" "$(row h2 0 0 1 0 0)" > "$T/two"
nothing_ran "$T/two" && ok "every host unreachable at fact gathering: rerun" || bad "two-host fact-gathering log must allow the rerun"

play "$GF" "$UNR" -- "$(row h1 12 3 0 0 0)" "$(row h2 0 0 1 0 0)" > "$T/partial"
nothing_ran "$T/partial" && bad "a host that ran tasks must block the rerun" || ok "one host ran tasks: no rerun"

play "$GF" 'TASK [install] *****' "$UNR" -- "$(row h1 4 0 1 0 0)" > "$T/midplay"
nothing_ran "$T/midplay" && bad "unreachable mid-play must block the rerun" || ok "unreachable mid-play: no rerun"

# gather_facts: false, a loop item done before the next item went unreachable:
# the recap totals are all zero, the TASK header gives it away.
play 'TASK [write config] ****' 'changed: [h1] => (item=a)' "$UNR" -- "$(row h1 0 0 1 0 0)" > "$T/loop"
nothing_ran "$T/loop" && bad "a user task started must block the rerun" || ok "user task started (zero totals): no rerun"
play "$GF" 'changed: [h1] => (item=a)' "$UNR" -- "$(row h1 0 0 1 0 0)" > "$T/loopgf"
nothing_ran "$T/loopgf" && bad "a loop task named Gathering Facts must block the rerun" || ok "loop task named Gathering Facts: no rerun"

play "$GF" "$UNR" -- "$(row h1 0 0 1 0 1)" > "$T/rescued"
nothing_ran "$T/rescued" && bad "rescued=1 must block the rerun" || ok "rescued task: no rerun"

play "$GF" -- "$(row h1 0 0 0 1 0)" > "$T/failed"
nothing_ran "$T/failed" && bad "a failed task must block the rerun" || ok "failed task: no rerun"

printf 'ERROR! the playbook could not be found\n' > "$T/norecap"
nothing_ran "$T/norecap" && bad "no PLAY RECAP must block the rerun" || ok "no recap: no rerun"

[ "$fail" -eq 0 ] && echo "unreachable-retry: all ok" || { echo "unreachable-retry: $fail failed"; exit 1; }
