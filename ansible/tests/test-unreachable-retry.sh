#!/usr/bin/env bash
# Runs `nothing_ran` from the Execute Ansible step of ansible-run.yml (the block
# between its >>>/<<< markers, extracted, not copied) against PLAY RECAPs, and
# checks it allows the one rerun only when no task ran on any host.
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
recap() { printf 'PLAY RECAP *********************************************************************\n'; printf '%s\n' "$@"; }

# asbo 44544069208 attempt 1, colours as ANSIBLE_FORCE_COLOR prints them
recap "${E}[0;31meu-omega-aws-asbo-01${E}[0m       : ok=0    changed=0    ${E}[1;31munreachable=1   ${E}[0m failed=0    skipped=0    rescued=0    ignored=0   " > "$T/asbo"
nothing_ran "$T/asbo" && ok "unreachable at Gathering Facts, single host: rerun" || bad "asbo recap must allow the rerun"

recap "h1 : ok=0    changed=0    unreachable=1    failed=0    skipped=0" \
      "h2 : ok=0    changed=0    unreachable=1    failed=0    skipped=0" > "$T/two"
nothing_ran "$T/two" && ok "every host unreachable before any task: rerun" || bad "two-host no-op recap must allow the rerun"

recap "h1 : ok=12   changed=3    unreachable=0    failed=0    skipped=0" \
      "h2 : ok=0    changed=0    unreachable=1    failed=0    skipped=0" > "$T/partial"
nothing_ran "$T/partial" && bad "a host that ran tasks must block the rerun" || ok "one host ran tasks: no rerun"

recap "h1 : ok=4    changed=0    unreachable=1    failed=0    skipped=0" > "$T/midplay"
nothing_ran "$T/midplay" && bad "unreachable mid-play (ok>0) must block the rerun" || ok "unreachable mid-play: no rerun"

recap "h1 : ok=0    changed=0    unreachable=0    failed=1    skipped=0" > "$T/failed"
nothing_ran "$T/failed" && bad "a failed task must block the rerun" || ok "failed task: no rerun"

printf 'ERROR! the playbook could not be found\n' > "$T/norecap"
nothing_ran "$T/norecap" && bad "no PLAY RECAP must block the rerun" || ok "no recap: no rerun"

[ "$fail" -eq 0 ] && echo "unreachable-retry: all ok" || { echo "unreachable-retry: $fail failed"; exit 1; }
