#!/usr/bin/env bash
# Unit-test the host_limit selector extracted verbatim from ansible-os-update.yml's
# enumerate step. Run: bash .github/workflows/test-host-limit-jq.sh
#
# Every case asserts BOTH the emitted host list AND the exit status — an error()
# that still exits 0 would be a silent pass, which is the whole failure class
# this validation exists to close.
set -uo pipefail

GROUP=us_omega_lw_kubernetes
INV=$(mktemp)
trap 'rm -f "$INV"' EXIT
cat > "$INV" <<EOF
{"$GROUP": {"hosts": ["node-a", "node-b", "node-c"]},
 "other_group": {"hosts": ["elsewhere"]}}
EOF

select_hosts() {  # <-- keep byte-identical to the workflow
  jq -c --arg g "$GROUP" --arg h "$1" '
    ($h | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))) as $want
    | (.[$g].hosts // []) as $have
    | ($want - $have) as $bogus
    | ($want | group_by(.) | map(select(length > 1) | .[0])) as $dupes
    | if ($want | length) == 0
      then error("host_limit is only separators: \($h)")
      elif ($bogus | length) > 0
      then error("hosts not in group \($g): \($bogus | join(", "))")
      elif ($dupes | length) > 0
      then error("duplicate hosts in host_limit: \($dupes | join(", "))")
      else $want end' "$INV" 2>&1
}

fail=0
check() {  # check <desc> <input> <want_rc> <want_substring>
  local desc="$1" in="$2" want_rc="$3" want="$4" out rc
  out=$(select_hosts "$in"); rc=$?
  if [ "$rc" != "$want_rc" ] || ! printf '%s' "$out" | grep -qF -- "$want"; then
    echo "FAIL  $desc"
    echo "        input=[$in]"
    echo "        got   rc=$rc out=$out"
    echo "        want  rc=$want_rc containing [$want]"
    fail=1
  else
    echo "ok    $desc"
  fi
}

# --- backward compatibility: the single-host escape hatch must be unchanged ---
check "single host -> one-element array"        "node-b"              0 '["node-b"]'

# --- the new capability ---
check "CSV batch keeps the given ORDER"        "node-c,node-a"       0 '["node-c","node-a"]'
check "whitespace around names is trimmed"     " node-a , node-b "   0 '["node-a","node-b"]'
check "trailing separator is ignored"          "node-a,"             0 '["node-a"]'

# --- the failures that must be loud, not silent ---
check "typo'd host is named and refused"       "node-a,node-x"       5 'hosts not in group'
check "  ...and the bad name is quoted"        "node-a,node-x"       5 'node-x'
check "host from another group is refused"     "elsewhere"           5 'hosts not in group'
check "duplicate would double a matrix leg"    "node-a,node-a"       5 'duplicate hosts'
check "separators only -> refused"             ",,"                  5 'only separators'

# An unknown group needs its own group name, so it cannot go through check().
# It is the case that matters most: `.[$g].hosts // []` turns a group that is not
# there into an empty list, and without the bogus-check that reads as "nothing to
# object to" rather than "the inventory does not have this group".
out=$(GROUP=nope; jq -c --arg g "nope" --arg h "node-a" '
  ($h | split(",") | map(gsub("^\\s+|\\s+$";""))) as $want
  | (.[$g].hosts // []) as $have
  | if (($want - $have) | length) > 0 then error("hosts not in group \($g)") else $want end' "$INV" 2>&1); rc=$?
if [ "$rc" = "5" ] && printf '%s' "$out" | grep -qF 'hosts not in group'; then
  echo "ok    missing group -> refused (not an empty pass)"
else
  echo "FAIL  missing group -> refused; got rc=$rc out=$out"; fail=1
fi

# --- invariant: nothing may emit a host list unless it exited 0 ---
for probe in "node-a" "node-a,node-b" "node-x" ",," "node-a,node-a"; do
  out=$(select_hosts "$probe"); rc=$?
  if [ "$rc" != "0" ] && printf '%s' "$out" | grep -q '^\['; then
    echo "FAIL  invariant: [$probe] printed a host list while exiting $rc"; fail=1
  fi
done
[ "$fail" = 0 ] && echo "ok    invariant: a host list is printed only on rc=0"

exit "$fail"
