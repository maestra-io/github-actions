#!/usr/bin/env bash
# Runs `hosts_verdict` from the Execute Ansible step of ansible-run.yml (the block
# between its >>>/<<< markers, extracted, not copied) against `--list-hosts` outputs.
# Offline: reads files, talks to nothing.
set -uo pipefail

WF=".github/workflows/ansible-run.yml"
fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed -n '/# >>> no-hosts-guard/,/# <<< no-hosts-guard/p' "$WF" | sed 's/^          //' > "$T/block.sh"
[ -s "$T/block.sh" ] || { echo "FAIL block markers not found in $WF"; exit 1; }
# shellcheck source=/dev/null
. "$T/block.sh"

check() { # <name> <want> <file>
  local got=0; hosts_verdict "$3" || got=$?
  if [ "$got" -eq "$2" ]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s: got %s, want %s\n' "$1" "$got" "$2"; fail=$((fail + 1)); fi
}

# asbo Deploy 45429247024: the Teleport inventory script failed, ansible went on.
cat > "$T/inv-failed" <<'TXT'
[WARNING]: Failed to parse inventory with 'script' plugin: Inventory script returned non-zero exit code 1.
[WARNING]: Unable to parse /w/infra/ansible/inventory/teleport_inventory.py as an inventory source
[WARNING]: No inventory was parsed, only implicit localhost is available
[WARNING]: Could not match supplied host pattern, ignoring: eu_omega_aws_asbo

playbook: playbooks/asbo.yml

  play #1 (eu_omega_aws_asbo): asbo host	TAGS: []
    pattern: ['eu_omega_aws_asbo']
    hosts (0):
TXT
check "a failed inventory script is not an empty group" 3 "$T/inv-failed"

cat > "$T/empty-group" <<'TXT'
[WARNING]: Could not match supplied host pattern, ignoring: us_omega_lw_mssql

playbook: playbooks/x.yml

  play #1 (us_omega_lw_mssql): x	TAGS: []
    pattern: ['us_omega_lw_mssql']
    hosts (0):
TXT
check "a loaded inventory with an empty group" 4 "$T/empty-group"

printf 'ERROR! Specified inventory, host pattern and/or --limit leaves us with no hosts to target.\n' > "$T/limit"
check "a --limit that leaves nothing" 4 "$T/limit"

cat > "$T/hosts" <<'TXT'
playbook: playbooks/x.yml

  play #1 (localhost): prepare	TAGS: []
    pattern: ['localhost']
    hosts (0):

  play #2 (eu_omega_aws_asbo): asbo host	TAGS: []
    pattern: ['eu_omega_aws_asbo']
    hosts (1):
      eu-omega-aws-asbo-01
TXT
check "one play with hosts is enough" 0 "$T/hosts"

printf "ERROR! couldn't resolve module/action 'nope'.\n" > "$T/broken"
check "a playbook error is left to the real run" 0 "$T/broken"

[ "$fail" -eq 0 ] && echo "all passed" || { echo "$fail failure(s)"; exit 1; }
